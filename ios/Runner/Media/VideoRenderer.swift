import AVFoundation
import CoreImage
import CoreText
import Foundation

private func videoRenderDiagnostic(_ message: @autoclosure () -> String) {
  #if DEBUG
    print(message())
  #endif
}

enum VideoRenderError: Error, Equatable {
  case unsupportedContract
  case missingAsset
  case sourceReadFailed
  case writerFailed
  case cancelled
}

enum VideoLayoutPayload: String, Decodable {
  case stacked
  case sequentialFocus
  case photoDump
}

enum RenderQualityPayload: String, Decodable {
  case preview
  case full

  var dimensions: (width: Int, height: Int) {
    switch self {
    case .preview: (360, 640)
    case .full: (1080, 1920)
    }
  }
}

struct ClipCropPayload: Decodable {
  let assetId: String
  let crop: NormalizedCropPayload
}

struct VideoCaptionPayload: Decodable {
  let text: String
  let x: Double
  let y: Double
  let destinationStartSample: Int
  let durationSamples: Int
}

struct VideoSceneEventPayload: Decodable {
  let destinationStartSample: Int
  let durationSamples: Int
  let assetIds: [String]
  let primaryAssetId: String?

  var destinationEndSample: Int { destinationStartSample + durationSamples }
}

struct VideoEffectsPayload: Decodable {
  let enabled: [String]
}

struct VideoRecipePayload: Decodable {
  let schemaVersion: Int
  let layout: VideoLayoutPayload
  let clipCrops: [ClipCropPayload]
  let captions: [VideoCaptionPayload]
  let events: [VideoSceneEventPayload]
  let effects: VideoEffectsPayload

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, layout, clipCrops, captions, events, effects
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    layout = try container.decode(VideoLayoutPayload.self, forKey: .layout)
    clipCrops = try container.decode([ClipCropPayload].self, forKey: .clipCrops)
    captions = try container.decode([VideoCaptionPayload].self, forKey: .captions)
    events = try container.decode([VideoSceneEventPayload].self, forKey: .events)
    effects = try container.decodeIfPresent(VideoEffectsPayload.self, forKey: .effects)
      ?? VideoEffectsPayload(enabled: [])
    let cropIds = clipCrops.map(\.assetId)
    guard schemaVersion == 1,
      (1...6).contains(clipCrops.count),
      captions.count <= 12,
      events.count <= 64,
      !events.isEmpty,
      Set(cropIds).count == cropIds.count,
      clipCrops.allSatisfy({ !$0.assetId.isEmpty && $0.crop.isValid }),
      effects.enabled.isEmpty,
      events.first?.destinationStartSample == 0,
      events.last?.destinationEndSample == ArrangementPayload.totalSamples
    else { throw VideoRenderError.unsupportedContract }
    for (index, event) in events.enumerated() {
      guard event.destinationStartSample >= 0,
        event.destinationStartSample % 90_000 == 0,
        event.durationSamples > 0,
        event.destinationEndSample <= ArrangementPayload.totalSamples,
        (1...3).contains(event.assetIds.count),
        event.assetIds.allSatisfy(cropIds.contains),
        event.primaryAssetId.map(event.assetIds.contains) ?? true,
        index == 0 || events[index - 1].destinationEndSample == event.destinationStartSample
      else { throw VideoRenderError.unsupportedContract }
    }
    for caption in captions {
      let (end, overflow) = caption.destinationStartSample.addingReportingOverflow(
        caption.durationSamples
      )
      guard !overflow, caption.text.count <= 80,
        caption.x.isFinite, caption.y.isFinite,
        (0...1).contains(caption.x), (0...1).contains(caption.y),
        caption.destinationStartSample >= 0,
        caption.durationSamples > 0,
        end <= ArrangementPayload.totalSamples
      else { throw VideoRenderError.unsupportedContract }
    }
  }
}

struct VideoRenderRequestPayload: Decodable {
  let schemaVersion: Int
  let operationId: String
  let projectId: String
  let revision: Int
  let arrangement: ArrangementPayload
  let video: VideoRecipePayload
  let quality: RenderQualityPayload

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, operationId, projectId, revision, arrangement, video, quality
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    operationId = try container.decode(String.self, forKey: .operationId)
    projectId = try container.decode(String.self, forKey: .projectId)
    revision = try container.decode(Int.self, forKey: .revision)
    arrangement = try container.decode(ArrangementPayload.self, forKey: .arrangement)
    video = try container.decode(VideoRecipePayload.self, forKey: .video)
    quality = try container.decode(RenderQualityPayload.self, forKey: .quality)
    guard schemaVersion == 1, !operationId.isEmpty, !projectId.isEmpty, revision >= 0,
      Set(video.clipCrops.map(\.assetId)) == Set(arrangement.sourceAssetIds)
    else { throw VideoRenderError.unsupportedContract }
  }
}

struct VideoRenderReport {
  let url: URL
  let frameCount: Int
  let width: Int
  let height: Int
}

struct VideoRenderer {
  static let frameCount = 450
  static let framesPerSecond = 30
  let audioRenderer: AudioRenderer
  private let context = CIContext(options: [.cacheIntermediates: false])

  init(audioRenderer: AudioRenderer = AudioRenderer()) {
    self.audioRenderer = audioRenderer
  }

  static func nearestFrame(forSample sample: Int) -> Int {
    (sample * framesPerSecond + 24_000) / 48_000
  }

  func render(
    request: VideoRenderRequestPayload,
    assets: [String: URL],
    outputURL: URL,
    cancellation: CancellationToken
  ) async throws -> VideoRenderReport {
    try checkCancellation(cancellation)
    let requiredIds = Set(request.arrangement.sourceAssetIds)
    guard requiredIds.allSatisfy({ assets[$0] != nil }) else {
      throw VideoRenderError.missingAsset
    }
    let audioURL = outputURL.deletingPathExtension().appendingPathExtension("caf")
    defer { try? FileManager.default.removeItem(at: audioURL) }
    _ = try await audioRenderer.render(
      arrangement: request.arrangement,
      assets: assets,
      outputURL: audioURL,
      cancellation: cancellation
    )
    videoRenderDiagnostic("VIDEO_STAGE audio_complete")
    try checkCancellation(cancellation)

    let dimensions = request.quality.dimensions
    let providers = try await makeProviders(
      assets: assets,
      requiredIds: requiredIds,
      cancellation: cancellation
    )
    videoRenderDiagnostic("VIDEO_STAGE providers_ready count=\(providers.count)")
    if FileManager.default.fileExists(atPath: outputURL.path) {
      try FileManager.default.removeItem(at: outputURL)
    }
    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
    let videoInput = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264,
        AVVideoWidthKey: dimensions.width,
        AVVideoHeightKey: dimensions.height,
        AVVideoCompressionPropertiesKey: [
          AVVideoAverageBitRateKey: request.quality == .full ? 8_000_000 : 900_000,
          AVVideoExpectedSourceFrameRateKey: Self.framesPerSecond,
          AVVideoMaxKeyFrameIntervalKey: Self.framesPerSecond,
        ],
        AVVideoColorPropertiesKey: [
          AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
          AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
          AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
        ],
      ]
    )
    videoInput.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: videoInput,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        kCVPixelBufferWidthKey as String: dimensions.width,
        kCVPixelBufferHeightKey as String: dimensions.height,
        kCVPixelBufferIOSurfacePropertiesKey as String: [:],
      ]
    )
    let audioInput = AVAssetWriterInput(
      mediaType: .audio,
      outputSettings: [
        AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48_000,
        AVNumberOfChannelsKey: 1,
        AVEncoderBitRateKey: 128_000,
      ]
    )
    audioInput.expectsMediaDataInRealTime = false
    guard writer.canAdd(videoInput), writer.canAdd(audioInput) else {
      throw VideoRenderError.writerFailed
    }
    writer.add(videoInput)
    writer.add(audioInput)
    guard writer.startWriting() else { throw VideoRenderError.writerFailed }
    videoRenderDiagnostic("VIDEO_STAGE writer_started status=\(writer.status.rawValue)")
    writer.startSession(atSourceTime: .zero)

    let audioTask = Task { () -> Result<Void, Error> in
      do {
        try await appendAudio(
          audioURL,
          to: audioInput,
          videoInput: videoInput,
          writer: writer,
          cancellation: cancellation
        )
        audioInput.markAsFinished()
        videoRenderDiagnostic(
          "VIDEO_STAGE input_finished role=audio \(writerDiagnosticState(writer, videoInput: videoInput, audioInput: audioInput))"
        )
        return .success(())
      } catch {
        cancellation.cancel()
        return .failure(error)
      }
    }
    do {
      for frame in 0..<Self.frameCount {
        try checkCancellation(cancellation)
        try await waitUntilReady(
          videoInput,
          role: "video",
          index: frame,
          videoInput: videoInput,
          audioInput: audioInput,
          writer: writer,
          cancellation: cancellation
        )
        guard let pool = adaptor.pixelBufferPool else {
          throw VideoRenderError.writerFailed
        }
        var optionalBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optionalBuffer) == kCVReturnSuccess,
          let buffer = optionalBuffer
        else { throw VideoRenderError.writerFailed }
        try await drawFrame(
          frame,
          request: request,
          providers: providers,
          into: buffer,
          width: dimensions.width,
          height: dimensions.height
        )
        guard adaptor.append(
          buffer,
          withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)
        ) else {
          videoRenderDiagnostic(
            "VIDEO_STAGE append_failed role=video index=\(frame) \(writerDiagnosticState(writer, videoInput: videoInput, audioInput: audioInput))"
          )
          throw VideoRenderError.writerFailed
        }
        if frame == 0 { videoRenderDiagnostic("VIDEO_STAGE first_video_append") }
      }
      videoInput.markAsFinished()
      videoRenderDiagnostic(
        "VIDEO_STAGE input_finished role=video \(writerDiagnosticState(writer, videoInput: videoInput, audioInput: audioInput))"
      )
      let audioResult = await audioTask.value
      try audioResult.get()
      writer.endSession(atSourceTime: CMTime(value: 15, timescale: 1))
      videoRenderDiagnostic(
        "VIDEO_STAGE finish_writing begin \(writerDiagnosticState(writer, videoInput: videoInput, audioInput: audioInput))"
      )
      await withCheckedContinuation { continuation in
        writer.finishWriting { continuation.resume() }
      }
      videoRenderDiagnostic(
        "VIDEO_STAGE finish_writing end \(writerDiagnosticState(writer, videoInput: videoInput, audioInput: audioInput))"
      )
      guard writer.status == .completed else { throw VideoRenderError.writerFailed }
      try checkCancellation(cancellation)
      return VideoRenderReport(
        url: outputURL,
        frameCount: Self.frameCount,
        width: dimensions.width,
        height: dimensions.height
      )
    } catch {
      cancellation.cancel()
      audioTask.cancel()
      let audioResult = await audioTask.value
      writer.cancelWriting()
      try? FileManager.default.removeItem(at: outputURL)
      if case let .failure(audioError) = audioResult {
        throw Self.preferredProducerError(primary: error, audio: audioError)
      }
      throw error
    }
  }

  static func preferredProducerError(primary: Error, audio: Error) -> Error {
    guard primary as? VideoRenderError == .cancelled,
      !isCancellationError(audio)
    else { return primary }
    return audio
  }

  private static func isCancellationError(_ error: Error) -> Bool {
    error is CancellationError || error as? VideoRenderError == .cancelled
  }

  private func makeProviders(
    assets: [String: URL],
    requiredIds: Set<String>,
    cancellation: CancellationToken
  ) async throws
    -> [String: SourceProvider]
  {
    var result: [String: SourceProvider] = [:]
    for id in requiredIds {
      guard let url = assets[id] else { throw VideoRenderError.missingAsset }
      let asset = AVURLAsset(url: url)
      let duration = try await asset.load(.duration)
      guard duration.isNumeric, duration > .zero else {
        throw VideoRenderError.sourceReadFailed
      }
      let generator = AVAssetImageGenerator(asset: asset)
      generator.appliesPreferredTrackTransform = true
      generator.dynamicRangePolicy = .forceSDR
      let halfFrame = CMTime(value: 1, timescale: 60)
      generator.requestedTimeToleranceBefore = halfFrame
      generator.requestedTimeToleranceAfter = halfFrame
      guard let track = try await asset.loadTracks(withMediaType: .video).first else {
        throw VideoRenderError.sourceReadFailed
      }
      let timestamps = try sourceTimestamps(
        asset: asset,
        track: track,
        cancellation: cancellation
      )
      result[id] = SourceProvider(
        generator: generator,
        duration: duration,
        timestamps: timestamps
      )
    }
    return result
  }

  func sourceTimestamps(
    asset: AVAsset,
    track: AVAssetTrack,
    cancellation: CancellationToken? = nil
  ) throws -> [CMTime] {
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else {
      videoRenderDiagnostic("VIDEO_STAGE source_pts_reader cannot_add_output")
      throw VideoRenderError.sourceReadFailed
    }
    reader.add(output)
    guard reader.startReading() else {
      videoRenderDiagnostic("VIDEO_STAGE source_pts_reader start_failed")
      throw VideoRenderError.sourceReadFailed
    }
    var timestamps: [CMTime] = []
    var scannedSamples = 0
    while let sample = output.copyNextSampleBuffer() {
      if let cancellation { try checkCancellation(cancellation) }
      scannedSamples += 1
      guard scannedSamples <= 2_100 else {
        videoRenderDiagnostic(
          "VIDEO_STAGE source_pts_reader scan_cap scanned=\(scannedSamples) frames=\(timestamps.count)"
        )
        throw VideoRenderError.sourceReadFailed
      }
      if let timestamp = try Self.sourceTimestamp(from: sample) {
        guard timestamps.count < 2_000 else {
          videoRenderDiagnostic(
            "VIDEO_STAGE source_pts_reader frame_cap count=\(timestamps.count)"
          )
          throw VideoRenderError.sourceReadFailed
        }
        timestamps.append(timestamp)
      }
    }
    videoRenderDiagnostic(
      "VIDEO_STAGE source_pts_reader status=\(reader.status.rawValue) count=\(timestamps.count) error=\(String(reflecting: reader.error))"
    )
    if let error = reader.error {
      videoRenderDiagnostic(
        "VIDEO_STAGE source_pts_reader_error reflected=\(String(reflecting: error))"
      )
      throw error
    }
    guard reader.status == .completed, !timestamps.isEmpty else {
      videoRenderDiagnostic(
        "VIDEO_STAGE source_pts_reader incomplete_or_empty status=\(reader.status.rawValue) count=\(timestamps.count)"
      )
      throw VideoRenderError.sourceReadFailed
    }
    return timestamps.sorted { CMTimeCompare($0, $1) < 0 }
  }

  static func sourceTimestamp(from sample: CMSampleBuffer) throws -> CMTime? {
    let sampleCount = CMSampleBufferGetNumSamples(sample)
    if sampleCount == 0 {
      let attachments = CMCopyDictionaryOfAttachments(
        allocator: kCFAllocatorDefault,
        target: sample,
        attachmentMode: kCMAttachmentMode_ShouldPropagate
      ) as? [AnyHashable: Any]
      let keys = attachments?.keys.map { String(describing: $0) }.sorted() ?? []
      videoRenderDiagnostic(
        "VIDEO_STAGE source_pts_reader skipped_marker samples=0 keys=\(keys)"
      )
      return nil
    }
    do {
      return try sourceTimestamp(
        sampleCount: sampleCount,
        presentationTimestamp: CMSampleBufferGetPresentationTimeStamp(sample)
      )
    } catch {
      videoRenderDiagnostic(
        "VIDEO_STAGE source_pts_reader invalid_media_pts samples=\(sampleCount)"
      )
      throw error
    }
  }

  static func sourceTimestamp(
    sampleCount: Int,
    presentationTimestamp: CMTime
  ) throws -> CMTime? {
    guard sampleCount > 0 else { return nil }
    guard presentationTimestamp.isNumeric else { throw VideoRenderError.sourceReadFailed }
    return presentationTimestamp
  }

  private func drawFrame(
    _ frame: Int,
    request: VideoRenderRequestPayload,
    providers: [String: SourceProvider],
    into buffer: CVPixelBuffer,
    width: Int,
    height: Int
  ) async throws {
    let sample = frame * 1_600
    guard let scene = request.video.events.first(where: {
      sample >= $0.destinationStartSample && sample < $0.destinationEndSample
    }) else { throw VideoRenderError.unsupportedContract }
    var canvas = CIImage(color: CIColor.black).cropped(
      to: CGRect(x: 0, y: 0, width: width, height: height)
    )
    let targets = Self.targetRects(
      count: scene.assetIds.count,
      layout: request.video.layout,
      width: CGFloat(width),
      height: CGFloat(height)
    )
    for (index, id) in scene.assetIds.enumerated() {
      guard let provider = providers[id],
        let crop = request.video.clipCrops.first(where: { $0.assetId == id })?.crop
      else { throw VideoRenderError.missingAsset }
      let sourceTime = sourceTime(
        assetId: id,
        sample: sample,
        events: request.arrangement.videoEvents,
        duration: provider.duration
      )
      let image = CIImage(cgImage: try await provider.image(at: sourceTime))
      let sourceCrop = CGRect(
        x: image.extent.minX + CGFloat(crop.x) * image.extent.width,
        y: image.extent.minY + CGFloat(1 - crop.y - crop.height) * image.extent.height,
        width: CGFloat(crop.width) * image.extent.width,
        height: CGFloat(crop.height) * image.extent.height
      )
      let cropped = image.cropped(to: sourceCrop)
      let target = targets[index]
      let scale = max(target.width / cropped.extent.width, target.height / cropped.extent.height)
      let scaled = cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
      let translated = scaled.transformed(
        by: CGAffineTransform(
          translationX: target.midX - scaled.extent.midX,
          y: target.midY - scaled.extent.midY
        )
      ).cropped(to: target)
      canvas = translated.composited(over: canvas)
    }
    context.render(
      canvas,
      to: buffer,
      bounds: CGRect(x: 0, y: 0, width: width, height: height),
      colorSpace: CGColorSpace(name: CGColorSpace.itur_709)
    )
    try drawCaptions(
      request.video.captions.filter {
        sample >= $0.destinationStartSample
          && sample < $0.destinationStartSample + $0.durationSamples
      },
      into: buffer,
      width: width,
      height: height
    )
  }

  static func targetRects(
    count: Int,
    layout: VideoLayoutPayload,
    width: CGFloat,
    height: CGFloat
  ) -> [CGRect] {
    switch layout {
    case .stacked:
      let row = height / CGFloat(count)
      return (0..<count).map {
        CGRect(
          x: 0,
          y: height - CGFloat($0 + 1) * row,
          width: width,
          height: row
        )
      }
    case .sequentialFocus:
      return Array(repeating: CGRect(x: 0, y: 0, width: width, height: height), count: count)
    case .photoDump:
      let inset = width * 0.06
      let cardWidth = width * 0.74
      let cardHeight = height * 0.48
      return (0..<count).map { index in
        let top = height * (0.08 + CGFloat(index) * 0.17)
        return CGRect(
          x: inset + CGFloat(index) * width * 0.08,
          y: height - top - cardHeight,
          width: cardWidth,
          height: cardHeight
        )
      }
    }
  }

  private func sourceTime(
    assetId: String,
    sample: Int,
    events: [VideoEventPayload],
    duration: CMTime
  ) -> CMTime {
    guard let event = events.last(where: {
      $0.assetId == assetId && $0.destinationStartSample <= sample
    }) ?? events.first(where: { $0.assetId == assetId }) else { return .zero }
    let offset = max(0, sample - event.destinationStartSample)
    var requested = CMTime(
      value: CMTimeValue(event.sourceVideoStartTime.numerator + offset),
      timescale: CMTimeScale(event.sourceVideoStartTime.denominator)
    )
    if requested >= duration {
      switch event.loopMode {
      case .once, .hold:
        requested = CMTimeMaximum(.zero, duration - CMTime(value: 1, timescale: 600))
      case .loop:
        let durationSeconds = CMTimeGetSeconds(duration)
        let seconds = CMTimeGetSeconds(requested).truncatingRemainder(dividingBy: durationSeconds)
        requested = CMTime(seconds: seconds, preferredTimescale: 48_000)
      }
    }
    return requested
  }

  private func drawCaptions(
    _ captions: [VideoCaptionPayload],
    into buffer: CVPixelBuffer,
    width: Int,
    height: Int
  ) throws {
    guard !captions.isEmpty else { return }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer),
      let graphics = CGContext(
        data: base,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
          | CGImageAlphaInfo.premultipliedFirst.rawValue
      )
    else { throw VideoRenderError.writerFailed }
    for caption in captions {
      let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
          "Helvetica-Bold" as CFString,
          CGFloat(width) * 0.055,
          nil
        ),
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(
          red: 1,
          green: 1,
          blue: 1,
          alpha: 1
        ),
      ]
      let text = NSAttributedString(string: caption.text, attributes: attributes)
      let setter = CTFramesetterCreateWithAttributedString(text)
      let rect = CGRect(
        x: CGFloat(caption.x) * CGFloat(width),
        y: CGFloat(1 - caption.y) * CGFloat(height) - CGFloat(height) * 0.12,
        width: CGFloat(width) * 0.9,
        height: CGFloat(height) * 0.12
      )
      let path = CGPath(rect: rect, transform: nil)
      CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(), path, nil), graphics)
    }
  }

  private func appendAudio(
    _ url: URL,
    to input: AVAssetWriterInput,
    videoInput: AVAssetWriterInput,
    writer: AVAssetWriter,
    cancellation: CancellationToken
  ) async throws {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else {
      throw VideoRenderError.sourceReadFailed
    }
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
    guard reader.canAdd(output) else { throw VideoRenderError.sourceReadFailed }
    reader.add(output)
    guard reader.startReading() else { throw VideoRenderError.sourceReadFailed }
    var sampleIndex = 0
    while let sample = output.copyNextSampleBuffer() {
      try checkCancellation(cancellation)
      try await waitUntilReady(
        input,
        role: "audio",
        index: sampleIndex,
        videoInput: videoInput,
        audioInput: input,
        writer: writer,
        cancellation: cancellation
      )
      guard input.append(sample) else {
        videoRenderDiagnostic(
          "VIDEO_STAGE append_failed role=audio index=\(sampleIndex) \(writerDiagnosticState(writer, videoInput: videoInput, audioInput: input))"
        )
        throw VideoRenderError.writerFailed
      }
      if sampleIndex == 0 {
        videoRenderDiagnostic(
          "VIDEO_STAGE first_audio_append \(writerDiagnosticState(writer, videoInput: videoInput, audioInput: input))"
        )
      }
      sampleIndex += 1
    }
    videoRenderDiagnostic(
      "VIDEO_STAGE audio_eof samples=\(sampleIndex) readerStatus=\(reader.status.rawValue) readerError=\(String(reflecting: reader.error)) \(writerDiagnosticState(writer, videoInput: videoInput, audioInput: input))"
    )
    guard reader.status == .completed else { throw VideoRenderError.sourceReadFailed }
  }

  private func waitUntilReady(
    _ input: AVAssetWriterInput,
    role: String,
    index: Int,
    videoInput: AVAssetWriterInput,
    audioInput: AVAssetWriterInput,
    writer: AVAssetWriter,
    cancellation: CancellationToken
  ) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(30))
    while !input.isReadyForMoreMediaData {
      try checkCancellation(cancellation)
      guard writer.status == .writing else {
        videoRenderDiagnostic(
          "VIDEO_STAGE readiness_failed role=\(role) index=\(index) reason=writer_status \(writerDiagnosticState(writer, videoInput: videoInput, audioInput: audioInput))"
        )
        throw VideoRenderError.writerFailed
      }
      guard clock.now < deadline else {
        videoRenderDiagnostic(
          "VIDEO_STAGE readiness_failed role=\(role) index=\(index) reason=deadline \(writerDiagnosticState(writer, videoInput: videoInput, audioInput: audioInput))"
        )
        throw VideoRenderError.writerFailed
      }
      try await Task.sleep(nanoseconds: 1_000_000)
    }
  }

  private func writerDiagnosticState(
    _ writer: AVAssetWriter,
    videoInput: AVAssetWriterInput,
    audioInput: AVAssetWriterInput
  ) -> String {
    let reflectedError = String(reflecting: writer.error.map { $0 as NSError })
    return "writerStatus=\(writer.status.rawValue) writerError=\(reflectedError) videoReady=\(videoInput.isReadyForMoreMediaData) audioReady=\(audioInput.isReadyForMoreMediaData)"
  }

  private func checkCancellation(_ token: CancellationToken) throws {
    if token.isCancelled || Task.isCancelled { throw VideoRenderError.cancelled }
  }
}

private final class SourceProvider {
  let generator: AVAssetImageGenerator
  let duration: CMTime
  let timestamps: [CMTime]

  private var cachedFrame: Int?
  private var cachedImage: CGImage?

  init(generator: AVAssetImageGenerator, duration: CMTime, timestamps: [CMTime]) {
    self.generator = generator
    self.duration = duration
    self.timestamps = timestamps
  }

  func image(at time: CMTime) async throws -> CGImage {
    let index = heldFrameIndex(at: time)
    if cachedFrame == index, let cachedImage { return cachedImage }
    let generated: (image: CGImage, actualTime: CMTime)
    do {
      generated = try await generator.image(at: timestamps[index])
    } catch {
      let nsError = error as NSError
      videoRenderDiagnostic(
        "VIDEO_STAGE generator_error reflected=\(String(reflecting: error)) domain=\(nsError.domain) code=\(nsError.code)"
      )
      throw error
    }
    if cachedImage == nil {
      videoRenderDiagnostic("VIDEO_STAGE first_generator_image index=\(index)")
    }
    cachedFrame = index
    cachedImage = generated.image
    return generated.image
  }

  private func heldFrameIndex(at time: CMTime) -> Int {
    var lower = 0
    var upper = timestamps.count
    while lower < upper {
      let middle = (lower + upper) / 2
      if CMTimeCompare(timestamps[middle], time) <= 0 {
        lower = middle + 1
      } else {
        upper = middle
      }
    }
    return max(0, lower - 1)
  }
}
