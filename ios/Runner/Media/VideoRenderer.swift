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
  case buildUp
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
      videoEvents: request.arrangement.videoEvents,
      scenes: request.video.events,
      layout: request.video.layout,
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
    let writerProgress = VideoWriterProgress()
    let watchdog = VideoWriterWatchdog(progress: writerProgress) {
      cancellation.cancel()
      providers.values.forEach { $0.cancelImageGeneration() }
      writer.cancelWriting()
      videoRenderDiagnostic(
        "VIDEO_STAGE writer_watchdog stalled \(writerDiagnosticState(writer, videoInput: videoInput, audioInput: audioInput))"
      )
    }
    let watchdogTask = Task {
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 250_000_000)
        guard !Task.isCancelled else { break }
        if cancellation.isCancelled || writer.status == .failed || writer.status == .cancelled {
          providers.values.forEach { $0.cancelImageGeneration() }
          writer.cancelWriting()
          break
        }
        if watchdog.check() { break }
      }
    }

    let audioTask = Task { () -> Result<Void, Error> in
      do {
        try await appendAudio(
          audioURL,
          to: audioInput,
          videoInput: videoInput,
          writer: writer,
          cancellation: cancellation,
          progress: writerProgress
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
          cancellation: cancellation,
          progress: writerProgress
        )
        guard let pool = adaptor.pixelBufferPool else {
          throw VideoRenderError.writerFailed
        }
        var optionalBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optionalBuffer) == kCVReturnSuccess,
          let buffer = optionalBuffer
        else { throw VideoRenderError.writerFailed }
        try await withTaskCancellationHandler(operation: {
          try await drawFrame(
            frame,
            request: request,
            providers: providers,
            into: buffer,
            width: dimensions.width,
            height: dimensions.height
          )
        }, onCancel: {
          providers.values.forEach { $0.cancelImageGeneration() }
        })
        guard adaptor.append(
          buffer,
          withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)
        ) else {
          videoRenderDiagnostic(
            "VIDEO_STAGE append_failed role=video index=\(frame) \(writerDiagnosticState(writer, videoInput: videoInput, audioInput: audioInput))"
          )
          throw VideoRenderError.writerFailed
        }
        writerProgress.markProgress()
        if frame == 0 || frame % 30 == 0 || frame == Self.frameCount - 1 {
          videoRenderDiagnostic(
            "VIDEO_STAGE video_frame frame=\(frame) pts=\(CMTime(value: CMTimeValue(frame), timescale: 30))"
          )
        }
        if frame == 0 { videoRenderDiagnostic("VIDEO_STAGE first_video_append") }
      }
      videoInput.markAsFinished()
      videoRenderDiagnostic(
        "VIDEO_STAGE input_finished role=video \(writerDiagnosticState(writer, videoInput: videoInput, audioInput: audioInput))"
      )
      let audioResult = await audioTask.value
      try audioResult.get()
      watchdogTask.cancel()
      _ = await watchdogTask.value
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
      watchdogTask.cancel()
      _ = await watchdogTask.value
      providers.values.forEach { $0.cancelImageGeneration() }
      audioTask.cancel()
      let audioResult = await audioTask.value
      writer.cancelWriting()
      try? FileManager.default.removeItem(at: outputURL)
      let primaryError: Error = watchdog.didStall ? VideoRenderError.writerFailed : error
      if case let .failure(audioError) = audioResult {
        throw Self.preferredProducerError(primary: primaryError, audio: audioError)
      }
      throw primaryError
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
    videoEvents: [VideoEventPayload],
    scenes: [VideoSceneEventPayload],
    layout: VideoLayoutPayload,
    cancellation: CancellationToken
  ) async throws
    -> [String: SourceProvider]
  {
    var sourceRanges = Self.sourceRangesByAsset(videoEvents: videoEvents)
    if layout == .buildUp {
      for scene in scenes.prefix(3) where scene.assetIds.count == 1 {
        let id = scene.assetIds[0]
        guard let anchor = videoEvents.first(where: { $0.assetId == id }) else { continue }
        let timescale = CMTimeScale(anchor.sourceVideoStartTime.denominator)
        let start = CMTime(
          value: CMTimeValue(anchor.sourceVideoStartTime.numerator),
          timescale: timescale
        )
        let duration = CMTime(value: 90_000, timescale: 48_000)
        sourceRanges[id, default: []].append(CMTimeRange(start: start, duration: duration))
      }
      sourceRanges = sourceRanges.mapValues(Self.mergeSourceRanges)
    }
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
        timeRanges: sourceRanges[id] ?? [],
        cancellation: cancellation
      )
      result[id] = SourceProvider(
        generator: generator,
        duration: duration,
        timestamps: timestamps,
        sourceRanges: sourceRanges[id] ?? []
      )
    }
    return result
  }

  static func sourceRangesByAsset(
    videoEvents: [VideoEventPayload]
  ) -> [String: [CMTimeRange]] {
    var ranges: [String: [CMTimeRange]] = [:]
    for event in videoEvents {
      guard event.sourceVideoStartTime.denominator > 0, event.durationSamples > 0 else {
        continue
      }
      let timescale = CMTimeScale(event.sourceVideoStartTime.denominator)
      let start = CMTime(
        value: CMTimeValue(event.sourceVideoStartTime.numerator),
        timescale: timescale
      )
      let duration = CMTime(value: CMTimeValue(event.durationSamples), timescale: timescale)
      guard start.isNumeric, duration.isNumeric, duration > .zero else { continue }
      ranges[event.assetId, default: []].append(
        CMTimeRange(start: start, duration: duration)
      )
    }
    return ranges.mapValues { mergeSourceRanges($0) }
  }

  private static func mergeSourceRanges(_ ranges: [CMTimeRange]) -> [CMTimeRange] {
    let sorted = ranges.sorted { CMTimeCompare($0.start, $1.start) < 0 }
    var merged: [CMTimeRange] = []
    for range in sorted {
      guard range.isValid, range.duration > .zero else { continue }
      guard let previous = merged.last else {
        merged.append(range)
        continue
      }
      let previousEnd = previous.end
      if CMTimeCompare(range.start, previousEnd) <= 0 {
        let end = CMTimeCompare(previousEnd, range.end) >= 0 ? previousEnd : range.end
        merged[merged.count - 1] = CMTimeRange(
          start: previous.start,
          end: end
        )
      } else {
        merged.append(range)
      }
    }
    return merged
  }

  func sourceTimestamps(
    asset: AVAsset,
    track: AVAssetTrack,
    timeRanges: [CMTimeRange] = [],
    cancellation: CancellationToken? = nil
  ) throws -> [CMTime] {
    var timestamps: [CMTime] = []
    var scannedSamples = 0
    let ranges = timeRanges.isEmpty ? [nil] : timeRanges.map(Optional.some)
    for range in ranges {
      let reader = try AVAssetReader(asset: asset)
      let output = AVAssetReaderTrackOutput(track: track, outputSettings: nil)
      output.alwaysCopiesSampleData = false
      let acceptedRange = range.map(Self.expandedSourceRange)
      if let range, let acceptedRange {
        reader.timeRange = acceptedRange
        videoRenderDiagnostic(
          "VIDEO_STAGE source_pts_reader bounded start=\(range.start) duration=\(range.duration)"
        )
      }
      guard reader.canAdd(output) else {
        videoRenderDiagnostic("VIDEO_STAGE source_pts_reader cannot_add_output")
        throw VideoRenderError.sourceReadFailed
      }
      reader.add(output)
      guard reader.startReading() else {
        videoRenderDiagnostic("VIDEO_STAGE source_pts_reader start_failed")
        throw VideoRenderError.sourceReadFailed
      }
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
          if let acceptedRange {
            if CMTimeCompare(timestamp, acceptedRange.start) < 0 ||
              CMTimeCompare(timestamp, acceptedRange.end) > 0 {
              continue
            }
          }
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
      guard reader.status == .completed else {
        videoRenderDiagnostic(
          "VIDEO_STAGE source_pts_reader incomplete status=\(reader.status.rawValue) count=\(timestamps.count)"
        )
        throw VideoRenderError.sourceReadFailed
      }
    }
    guard !timestamps.isEmpty else {
      videoRenderDiagnostic(
        "VIDEO_STAGE source_pts_reader incomplete_or_empty count=\(timestamps.count)"
      )
      throw VideoRenderError.sourceReadFailed
    }
    // Compressed packets may arrive in decode order (B-frames), not presentation order.
    return timestamps.sorted { CMTimeCompare($0, $1) < 0 }.reduce(into: [CMTime]()) { result, timestamp in
      if result.last.map({ CMTimeCompare($0, timestamp) != 0 }) ?? true {
        result.append(timestamp)
      }
    }
  }

  private static func expandedSourceRange(_ range: CMTimeRange) -> CMTimeRange {
    let boundary = CMTime(value: 1, timescale: 600)
    let start = CMTimeMaximum(.zero, range.start - boundary)
    let end = range.end + boundary
    return CMTimeRange(start: start, end: end)
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
    let visibleAssetIds = Self.visibleAssetIds(scene: scene, layout: request.video.layout)
    for (index, id) in visibleAssetIds.enumerated() {
      guard let provider = providers[id],
        let crop = request.video.clipCrops.first(where: { $0.assetId == id })?.crop
      else { throw VideoRenderError.missingAsset }
      let sourceTime = Self.sourceTime(
        assetId: id,
        sample: sample,
        events: request.arrangement.videoEvents,
        duration: provider.duration,
        continuousFromSample: request.video.layout == .buildUp &&
          scene.assetIds.count == 1 ? scene.destinationStartSample : nil,
        repeatFromSample: request.video.layout == .buildUp &&
          scene.assetIds.count > 1 && index == 0
          ? 3 * 90_000 : nil
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
    case .buildUp:
      switch count {
      case 1:
        return [CGRect(x: 0, y: 0, width: width, height: height)]
      case 2:
        return [
          CGRect(x: 0, y: 0, width: width, height: height * 0.45),
          CGRect(x: 0, y: height * 0.45, width: width, height: height * 0.55),
        ]
      default:
        return [
          CGRect(x: 0, y: 0, width: width, height: height * 0.45),
          CGRect(x: 0, y: height * 0.45, width: width / 2, height: height * 0.55),
          CGRect(x: width / 2, y: height * 0.45, width: width / 2, height: height * 0.55),
        ]
      }
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

  static func visibleAssetIds(
    scene: VideoSceneEventPayload,
    layout: VideoLayoutPayload
  ) -> [String] {
    guard layout == .sequentialFocus else { return scene.assetIds }
    if let primary = scene.primaryAssetId, scene.assetIds.contains(primary) {
      return [primary]
    }
    return Array(scene.assetIds.prefix(1))
  }

  static func sourceTime(
    assetId: String,
    sample: Int,
    events: [VideoEventPayload],
    duration: CMTime,
    continuousFromSample: Int? = nil,
    repeatFromSample: Int? = nil
  ) -> CMTime {
    let event = repeatFromSample == nil && continuousFromSample == nil
      ? (events.last(where: {
          $0.assetId == assetId && $0.destinationStartSample <= sample
        }) ?? events.first(where: { $0.assetId == assetId }))
      : events.first(where: { $0.assetId == assetId })
    guard let event else { return .zero }
    let eventDuration = max(1, event.durationSamples)
    let offset = max(0, sample - event.destinationStartSample)
    let timescale = CMTimeScale(event.sourceVideoStartTime.denominator)
    let boundedOffset: Int
    if let continuousFromSample {
      boundedOffset = max(0, sample - continuousFromSample)
    } else if let repeatFromSample {
      boundedOffset = max(0, sample - repeatFromSample) % eventDuration
    } else {
      switch event.loopMode {
      case .once, .hold:
        boundedOffset = min(eventDuration - 1, offset)
      case .loop:
        boundedOffset = offset % eventDuration
      }
    }
    let sourceSample = event.sourceVideoStartTime.numerator + boundedOffset
    let requested = CMTime(value: CMTimeValue(sourceSample), timescale: timescale)
    guard duration.isNumeric, duration > .zero else { return .zero }
    let lastFrame = CMTimeMaximum(.zero, duration - CMTime(value: 1, timescale: 600))
    return CMTimeMinimum(lastFrame, CMTimeMaximum(.zero, requested))
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
    cancellation: CancellationToken,
    progress: VideoWriterProgress
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
        cancellation: cancellation,
        progress: progress
      )
      guard input.append(sample) else {
        videoRenderDiagnostic(
          "VIDEO_STAGE append_failed role=audio index=\(sampleIndex) \(writerDiagnosticState(writer, videoInput: videoInput, audioInput: input))"
        )
        throw VideoRenderError.writerFailed
      }
      progress.markProgress()
      if sampleIndex == 0 || sampleIndex % 100 == 0 {
        videoRenderDiagnostic(
          "VIDEO_STAGE audio_sample index=\(sampleIndex) pts=\(CMSampleBufferGetPresentationTimeStamp(sample))"
        )
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
    cancellation: CancellationToken,
    progress: VideoWriterProgress
  ) async throws {
    while !input.isReadyForMoreMediaData {
      try checkCancellation(cancellation)
      guard writer.status == .writing else {
        videoRenderDiagnostic(
          "VIDEO_STAGE readiness_failed role=\(role) index=\(index) reason=writer_status \(writerDiagnosticState(writer, videoInput: videoInput, audioInput: audioInput))"
        )
        throw VideoRenderError.writerFailed
      }
      guard !progress.hasStalled else {
        videoRenderDiagnostic(
          "VIDEO_STAGE readiness_failed role=\(role) index=\(index) reason=no_progress \(writerDiagnosticState(writer, videoInput: videoInput, audioInput: audioInput))"
        )
        throw VideoRenderError.writerFailed
      }
      try await Task.sleep(nanoseconds: 10_000_000)
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

final class VideoWriterProgress: @unchecked Sendable {
  static let watchdogNanoseconds: UInt64 = 30_000_000_000

  private let lock = NSLock()
  private let now: () -> UInt64
  private var lastProgress: UInt64

  init(now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds }) {
    self.now = now
    lastProgress = now()
  }

  var hasStalled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return now() &- lastProgress >= Self.watchdogNanoseconds
  }

  func markProgress() {
    lock.lock()
    lastProgress = now()
    lock.unlock()
  }
}

final class VideoWriterWatchdog: @unchecked Sendable {
  private let onStall: () -> Void
  private var didFire = false
  private let lock = NSLock()
  let progress: VideoWriterProgress

  init(progress: VideoWriterProgress, onStall: @escaping () -> Void) {
    self.progress = progress
    self.onStall = onStall
  }

  convenience init(_ onStall: @escaping () -> Void) {
    self.init(progress: VideoWriterProgress(), onStall: onStall)
  }

  var didStall: Bool {
    lock.lock()
    defer { lock.unlock() }
    return didFire
  }

  @discardableResult
  func check() -> Bool {
    lock.lock()
    if didFire {
      lock.unlock()
      return true
    }
    lock.unlock()
    guard progress.hasStalled else { return false }
    lock.lock()
    if didFire {
      lock.unlock()
      return true
    }
    didFire = true
    lock.unlock()
    onStall()
    return true
  }
}

private final class SourceProvider {
  let generator: AVAssetImageGenerator
  let duration: CMTime
  let timestamps: [CMTime]
  let sourceRanges: [CMTimeRange]

  private var cachedFrame: Int?
  private var cachedImage: CGImage?

  init(
    generator: AVAssetImageGenerator,
    duration: CMTime,
    timestamps: [CMTime],
    sourceRanges: [CMTimeRange]
  ) {
    self.generator = generator
    self.duration = duration
    self.timestamps = timestamps
    self.sourceRanges = sourceRanges
  }

  func cancelImageGeneration() {
    generator.cancelAllCGImageGeneration()
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
