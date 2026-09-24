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

  var destinationEndSample: Int {
    let (end, overflow) = destinationStartSample.addingReportingOverflow(durationSamples)
    return overflow ? Int.max : end
  }
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
  let clipNames: [String: String]

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, layout, clipCrops, captions, events, effects, clipNames
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    layout = try container.decode(VideoLayoutPayload.self, forKey: .layout)
    clipCrops = try Self.decodeBounded(
      ClipCropPayload.self, from: container, forKey: .clipCrops, maximum: 6
    )
    captions = try Self.decodeBounded(
      VideoCaptionPayload.self, from: container, forKey: .captions, maximum: 12
    )
    events = try Self.decodeBounded(
      VideoSceneEventPayload.self, from: container, forKey: .events,
      maximum: ArrangementPayload.maximumEvents * 2 + 1
    )
    effects = try container.decodeIfPresent(VideoEffectsPayload.self, forKey: .effects)
      ?? VideoEffectsPayload(enabled: [])
    clipNames = try container.decodeIfPresent([String: String].self, forKey: .clipNames) ?? [:]
    let cropIds = clipCrops.map(\.assetId)
    guard schemaVersion == 1,
      (1...6).contains(clipCrops.count),
      captions.count <= 12,
      events.count <= ArrangementPayload.maximumEvents * 2 + 1,
      !events.isEmpty,
      Set(cropIds).count == cropIds.count,
      clipCrops.allSatisfy({ !$0.assetId.isEmpty && $0.crop.isValid }),
      clipNames.count <= 6,
      clipNames.allSatisfy({ cropIds.contains($0.key) &&
        !$0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        $0.value.count <= 40 }),
      effects.enabled.count <= 3,
      Set(effects.enabled).count == effects.enabled.count,
      effects.enabled.allSatisfy({ ["mirrorCuts", "beatPunch", "echoTiles"].contains($0) }),
      events.first?.destinationStartSample == 0,
      events.last?.destinationEndSample == ArrangementPayload.totalSamples
    else { throw VideoRenderError.unsupportedContract }
    for (index, event) in events.enumerated() {
      guard event.destinationStartSample >= 0,
        event.durationSamples > 0,
        event.destinationEndSample <= ArrangementPayload.totalSamples,
        (1...6).contains(event.assetIds.count),
        Set(event.assetIds).count == event.assetIds.count,
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

  private static func decodeBounded<Value: Decodable>(
    _ type: Value.Type,
    from container: KeyedDecodingContainer<CodingKeys>,
    forKey key: CodingKeys,
    maximum: Int
  ) throws -> [Value] {
    var values = try container.nestedUnkeyedContainer(forKey: key)
    if let count = values.count, count > maximum {
      throw VideoRenderError.unsupportedContract
    }
    var decoded: [Value] = []
    while !values.isAtEnd {
      guard decoded.count < maximum else { throw VideoRenderError.unsupportedContract }
      decoded.append(try values.decode(Value.self))
    }
    return decoded
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
    let requiredIds = Set(request.arrangement.videoEvents.map(\.assetId))
      .union(request.video.events.flatMap(\.assetIds))
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
    let waveformPeaks: [CGFloat]
    if request.video.layout == .buildUp {
      waveformPeaks = (try? Self.waveformPeaks(from: audioURL)) ?? []
    } else {
      waveformPeaks = []
    }

    let dimensions = request.quality.dimensions
    let providers = try await makeProviders(
      assets: assets,
      requiredIds: requiredIds,
      videoEvents: request.arrangement.videoEvents,
      scenes: request.video.events,
      layout: request.video.layout,
      maximumSize: CGSize(width: dimensions.width, height: dimensions.height),
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
            waveformPeaks: waveformPeaks,
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
    maximumSize: CGSize,
    cancellation: CancellationToken
  ) async throws
    -> [String: SourceProvider]
  {
    let sourceRanges = Self.sourceRangesByAsset(videoEvents: videoEvents)
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
      generator.maximumSize = maximumSize
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
      let duration = CMTime(value: CMTimeValue(event.effectiveSourceDurationSamples), timescale: timescale)
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
    waveformPeaks: [CGFloat],
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
    // The sound clock is authoritative even when opening an older bar-based
    // recipe. Never hide an audible source behind a silent selected picture.
    let active = request.arrangement.videoEvents.filter {
      sample >= $0.destinationStartSample && sample < $0.destinationStartSample + $0.durationSamples
    }
    let activeIds = Set(active.map(\.assetId))
    let visibleAssetIds = active.isEmpty
      ? Self.visibleAssetIds(scene: scene, layout: request.video.layout)
      : scene.assetIds.filter(activeIds.contains) + active.map(\.assetId)
        .filter { !scene.assetIds.contains($0) }
        .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
    // Sequential focus still foregrounds the speaker, but the other audible
    // voices get their own panels instead of being invisible.
    let renderLayout: VideoLayoutPayload = request.video.layout == .sequentialFocus && visibleAssetIds.count > 1
      ? .buildUp : request.video.layout
    let targets = Self.targetRects(
      count: visibleAssetIds.count,
      layout: renderLayout,
      width: CGFloat(width),
      height: CGFloat(height)
    )
    for (index, id) in visibleAssetIds.enumerated() {
      guard let provider = providers[id],
        let crop = request.video.clipCrops.first(where: { $0.assetId == id })?.crop
      else { throw VideoRenderError.missingAsset }
      let target = targets[index]
      let tileCount = request.video.effects.enabled.contains("echoTiles") || request.video.layout == .buildUp
        ? Self.buildUpTileCount(assetId: id, sample: sample, events: request.arrangement.events)
        : 1
      let activeVideoEvents = request.arrangement.videoEvents.filter { event in
        event.assetId == id && sample >= event.destinationStartSample &&
          sample < event.destinationStartSample + event.durationSamples
      }
      for (tileIndex, tile) in Self.tileRects(in: target, count: tileCount).enumerated() {
        let matchingEvents = activeVideoEvents.isEmpty
          ? request.arrangement.videoEvents
          : [activeVideoEvents[activeVideoEvents.count - 1
              - min(tileIndex, activeVideoEvents.count - 1)]]
        let sourceTime = Self.sourceTime(
          assetId: id,
          sample: sample,
          events: matchingEvents,
          duration: provider.duration
        )
        let image = CIImage(cgImage: try await provider.image(at: sourceTime))
        let sourceCrop = CGRect(
          x: image.extent.minX + CGFloat(crop.x) * image.extent.width,
          y: image.extent.minY + CGFloat(1 - crop.y - crop.height) * image.extent.height,
          width: CGFloat(crop.width) * image.extent.width,
          height: CGFloat(crop.height) * image.extent.height
        )
        var cropped = image.cropped(to: sourceCrop)
        let current = activeVideoEvents.isEmpty ? nil : matchingEvents.first
        if request.video.effects.enabled.contains("mirrorCuts"), current?.isMirrored == true {
          cropped = cropped.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1,
            tx: cropped.extent.minX + cropped.extent.maxX, ty: 0))
        }
        let audioEvent = current.flatMap { v in request.arrangement.events.first {
          $0.assetId == v.assetId && $0.destinationStartSample == v.destinationStartSample &&
            $0.durationSamples == v.durationSamples &&
            $0.effectiveSourceDurationSamples == v.effectiveSourceDurationSamples &&
            $0.sourceStartSample == v.sourceVideoStartTime.numerator
        }}
        let age = audioEvent.map { Self.musicalAccentAge(event: $0, sample: sample) } ?? 48_000
        let punch: CGFloat = request.video.effects.enabled.contains("beatPunch")
          ? 1 + 0.09 * CGFloat(max(0, 1 - Double(age) / 7_200)) : 1
        let scale = max(tile.width / cropped.extent.width, tile.height / cropped.extent.height) * punch
        let scaled = cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let translated = scaled.transformed(
          by: CGAffineTransform(
            translationX: tile.midX - scaled.extent.midX,
            y: tile.midY - scaled.extent.midY
          )
        ).cropped(to: tile)
        canvas = translated.composited(over: canvas)
      }
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
    if request.video.layout == .buildUp {
      try drawRhythmAccents(
        events: request.arrangement.events,
        sample: sample,
        visibleAssetIds: visibleAssetIds,
        targets: targets,
        waveformPeaks: waveformPeaks,
        into: buffer,
        width: width,
        height: height
      )
    }
    try drawSoundNames(
      names: request.video.clipNames,
      events: request.arrangement.events,
      sample: sample,
      visibleAssetIds: visibleAssetIds,
      targets: targets,
      layout: request.video.layout,
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
    guard count > 0 else { return [] }
    if count > 3 {
      let columns = 2
      let rows = (count + columns - 1) / columns
      return (0..<count).map { index in
        CGRect(x: CGFloat(index % columns) * width / CGFloat(columns),
          y: height - CGFloat(index / columns + 1) * height / CGFloat(rows),
          width: width / CGFloat(columns), height: height / CGFloat(rows))
      }
    }
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

  /// A beat can change inside a continuous spoken phrase. Animate that beat
  /// without seeking the source video back to the start of the sentence.
  static func musicalAccentAge(event: SoundEventPayload, sample: Int) -> Int {
    let offset = max(0, sample - event.destinationStartSample)
    let onset = event.pitchSteps?.last(where: { $0.offsetSamples <= offset })?.offsetSamples ?? 0
    return offset - onset
  }

  static func buildUpTileCount(
    assetId: String,
    sample: Int,
    events: [SoundEventPayload]
  ) -> Int {
    let voices = events.filter {
      $0.assetId == assetId && sample >= $0.destinationStartSample &&
        sample < $0.destinationStartSample + $0.durationSamples
    }.count
    return max(1, min(4, voices))
  }

  static func tileRects(in target: CGRect, count: Int) -> [CGRect] {
    switch count {
    case 2:
      if target.width < target.height * 0.7 {
        return [
          CGRect(x: target.minX, y: target.minY, width: target.width, height: target.height / 2),
          CGRect(x: target.minX, y: target.midY, width: target.width, height: target.height / 2),
        ]
      }
      return [
        CGRect(x: target.minX, y: target.minY, width: target.width / 2, height: target.height),
        CGRect(x: target.midX, y: target.minY, width: target.width / 2, height: target.height),
      ]
    case 3, 4:
      return (0..<count).map { index in
        CGRect(
          x: target.minX + CGFloat(index % 2) * target.width / 2,
          y: target.minY + CGFloat(index / 2) * target.height / 2,
          width: target.width / 2,
          height: target.height / 2
        )
      }
    default:
      return [target]
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
    duration: CMTime
  ) -> CMTime {
    let candidates = events.filter { $0.assetId == assetId }
      .sorted { $0.destinationStartSample < $1.destinationStartSample }
    let event = candidates.last(where: {
      sample >= $0.destinationStartSample &&
        sample < $0.destinationStartSample + $0.durationSamples
    }) ?? candidates.last(where: { $0.destinationStartSample <= sample }) ?? candidates.first
    guard let event else { return .zero }
    let eventDuration = max(1, event.durationSamples)
    let offset = min(eventDuration - 1, max(0, sample - event.destinationStartSample))
    let timescale = CMTimeScale(event.sourceVideoStartTime.denominator)
    let mappedOffset: Int
    if let sourceCount = event.sourceDurationSamples {
      mappedOffset = EverydayAudioDSP.sourceOffset(outputOffset: offset,
        sourceCount: sourceCount, reverse: event.isReversed)
    } else {
      // Legacy payloads retain their original once/hold timing.
      mappedOffset = offset
    }
    let sourceSample = event.sourceVideoStartTime.numerator + mappedOffset
    let requested = CMTime(value: CMTimeValue(sourceSample), timescale: timescale)
    guard duration.isNumeric, duration > .zero else { return .zero }
    let lastFrame = CMTimeMaximum(.zero, duration - CMTime(value: 1, timescale: 600))
    return CMTimeMinimum(lastFrame, CMTimeMaximum(.zero, requested))
  }

  private static func waveformPeaks(from url: URL) throws -> [CGFloat] {
    let file = try AVAudioFile(forReading: url)
    guard let buffer = AVAudioPCMBuffer(
      pcmFormat: file.processingFormat,
      frameCapacity: AVAudioFrameCount(ArrangementPayload.totalSamples)
    ) else { throw VideoRenderError.sourceReadFailed }
    try file.read(into: buffer, frameCount: buffer.frameCapacity)
    guard let samples = buffer.floatChannelData?[0] else {
      throw VideoRenderError.sourceReadFailed
    }
    var peaks = Array(repeating: CGFloat(0), count: frameCount)
    for sample in 0..<min(Int(buffer.frameLength), ArrangementPayload.totalSamples) {
      let frame = sample / 1_600
      peaks[frame] = max(peaks[frame], CGFloat(abs(samples[sample])))
    }
    return peaks
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
      let rect = Self.captionRect(for: caption, width: width, height: height)
      let attributes: [NSAttributedString.Key: Any] = [
        NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(
          "HiraginoSans-W6" as CFString,
          CGFloat(width) * 0.07,
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
      let path = CGPath(rect: rect, transform: nil)
      graphics.saveGState()
      graphics.setShadow(
        offset: CGSize(width: 0, height: -CGFloat(width) * 0.004),
        blur: CGFloat(width) * 0.018,
        color: CGColor(red: 0.08, green: 0.06, blue: 0.08, alpha: 0.85)
      )
      CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(), path, nil), graphics)
      graphics.restoreGState()

      let accentX = min(CGFloat(width) * 0.88, rect.maxX + CGFloat(width) * 0.01)
      let accentY = rect.maxY - CGFloat(width) * 0.015
      graphics.setStrokeColor(CGColor(red: 0.73, green: 0.63, blue: 1, alpha: 1))
      graphics.setLineCap(.round)
      graphics.setLineWidth(CGFloat(width) * 0.009)
      graphics.move(to: CGPoint(x: accentX, y: accentY))
      graphics.addLine(to: CGPoint(x: accentX + CGFloat(width) * 0.018,
                                   y: accentY + CGFloat(width) * 0.045))
      graphics.move(to: CGPoint(x: accentX + CGFloat(width) * 0.04,
                                y: accentY - CGFloat(width) * 0.012))
      graphics.addLine(to: CGPoint(x: accentX + CGFloat(width) * 0.068,
                                   y: accentY + CGFloat(width) * 0.012))
      graphics.strokePath()
    }
  }

  static func captionRect(for caption: VideoCaptionPayload, width: Int, height: Int) -> CGRect {
    let canvasWidth = CGFloat(width)
    let canvasHeight = CGFloat(height)
    let estimatedTextWidth = CGFloat(caption.text.count) * canvasWidth * 0.0665
    let labelWidth = min(canvasWidth * 0.84, max(canvasWidth * 0.26, estimatedTextWidth))
    let labelHeight = canvasHeight * 0.18
    let marginX = canvasWidth * 0.08
    let centerX = min(
      max(CGFloat(caption.x) * canvasWidth, marginX + labelWidth / 2),
      canvasWidth - marginX - labelWidth / 2
    )
    let top = min(max(CGFloat(caption.y) * canvasHeight, canvasHeight * 0.08),
                  canvasHeight * 0.74)
    return CGRect(
      x: centerX - labelWidth / 2,
      y: canvasHeight - top - labelHeight,
      width: labelWidth,
      height: labelHeight
    )
  }

  static func namedActiveAssetIds(
    names: [String: String],
    events: [SoundEventPayload],
    sample: Int,
    visibleAssetIds: [String]
  ) -> [String] {
    visibleAssetIds.filter { id in
      names[id] != nil && events.contains { event in
        event.assetId == id && event.gain > 0 &&
          sample >= event.destinationStartSample &&
          sample < event.destinationStartSample + event.durationSamples
      }
    }
  }

  private func drawSoundNames(
    names: [String: String],
    events: [SoundEventPayload],
    sample: Int,
    visibleAssetIds: [String],
    targets: [CGRect],
    layout: VideoLayoutPayload,
    into buffer: CVPixelBuffer,
    width: Int,
    height: Int
  ) throws {
    let activeIds = Self.namedActiveAssetIds(
      names: names, events: events, sample: sample, visibleAssetIds: visibleAssetIds
    )
    guard !activeIds.isEmpty else { return }
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

    let sticker = layout == .buildUp || layout == .photoDump
    for id in activeIds {
      guard let name = names[id], let index = visibleAssetIds.firstIndex(of: id),
        index < targets.count else { continue }
      let target = targets[index]
      let fontSize = max(12, min(CGFloat(width) * 0.055, target.width * 0.09))
      let padding = fontSize * 0.65
      let maxTextWidth = min(target.width * 0.78, CGFloat(width) * 0.78)
      let characterLimit = max(4, Int(maxTextWidth / fontSize) - 1)
      let displayed = name.count > characterLimit
        ? String(name.prefix(characterLimit - 1)) + "…" : name
      let font = CTFontCreateWithName("HiraginoSans-W6" as CFString, fontSize, nil)
      let foreground = sticker
        ? CGColor(red: 0.14, green: 0.10, blue: 0.15, alpha: 1)
        : CGColor(red: 1, green: 1, blue: 1, alpha: 1)
      let attributed = NSAttributedString(string: displayed, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): font,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): foreground,
      ])
      let line = CTLineCreateWithAttributedString(attributed)
      let textWidth = min(maxTextWidth, CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)))
      let labelWidth = min(target.width * 0.9, textWidth + padding * 2)
      let labelHeight = fontSize * 1.8
      let inset = max(CGFloat(width) * 0.035, target.width * 0.055)
      let x = sticker ? target.minX + inset : target.midX - labelWidth / 2
      let y = min(
        max(target.minY + target.height * 0.08, CGFloat(height) * 0.10),
        min(target.maxY - labelHeight - inset, CGFloat(height) * 0.88 - labelHeight)
      )
      let rect = CGRect(x: x, y: y, width: labelWidth, height: labelHeight)
      graphics.saveGState()
      let background = sticker
        ? CGColor(red: 1, green: 0.97, blue: 0.93, alpha: 0.94)
        : CGColor(red: 0.07, green: 0.05, blue: 0.10, alpha: 0.78)
      graphics.setFillColor(background)
      graphics.addPath(CGPath(
        roundedRect: rect,
        cornerWidth: sticker ? labelHeight * 0.18 : labelHeight * 0.5,
        cornerHeight: sticker ? labelHeight * 0.18 : labelHeight * 0.5,
        transform: nil
      ))
      graphics.fillPath()
      graphics.setFillColor(sticker
        ? CGColor(red: 0.99, green: 0.42, blue: 0.43, alpha: 1)
        : CGColor(red: 0.75, green: 0.62, blue: 1, alpha: 1))
      graphics.fill(CGRect(x: rect.minX, y: rect.minY,
                           width: max(2, fontSize * 0.17), height: labelHeight))
      graphics.clip(to: rect.insetBy(dx: padding * 0.5, dy: 0))
      graphics.textPosition = CGPoint(
        x: rect.minX + padding,
        y: rect.minY + (labelHeight - fontSize) * 0.5
      )
      CTLineDraw(line, graphics)
      graphics.restoreGState()
    }
  }

  private func drawRhythmAccents(
    events: [SoundEventPayload],
    sample: Int,
    visibleAssetIds: [String],
    targets: [CGRect],
    waveformPeaks: [CGFloat],
    into buffer: CVPixelBuffer,
    width: Int,
    height: Int
  ) throws {
    let active = events.filter { event in
      let elapsed = sample - event.destinationStartSample
      return elapsed >= 0 && elapsed < 9_600 && visibleAssetIds.contains(event.assetId)
    }
    let waveformEvent = events.last { event in
      let elapsed = sample - event.destinationStartSample
      return elapsed >= 0 && elapsed < 28_800
    }
    guard !active.isEmpty || (waveformEvent != nil && waveformPeaks.count == Self.frameCount)
    else { return }
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

    graphics.setLineCap(.round)
    if let waveformEvent, waveformPeaks.count == Self.frameCount {
      let fade = CGFloat(1 - Double(sample - waveformEvent.destinationStartSample) / 28_800)
      let centerY = CGFloat(height) * (visibleAssetIds.count > 1 ? 0.45 : 0.22)
      let step = CGFloat(width) * 0.88 / 48
      let currentFrame = sample / 1_600
      let path = CGMutablePath()
      for bar in 0..<48 {
        let frame = currentFrame + bar - 24
        let peak = waveformPeaks[max(0, min(Self.frameCount - 1, frame))]
        let barHeight = CGFloat(height) * (0.004 + 0.068 * min(CGFloat(1), peak).squareRoot())
        let x = CGFloat(width) * 0.06 + (CGFloat(bar) + 0.5) * step
        path.move(to: CGPoint(x: x, y: centerY - barHeight / 2))
        path.addLine(to: CGPoint(x: x, y: centerY + barHeight / 2))
      }
      graphics.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: fade * 0.15))
      graphics.fill(CGRect(
        x: 0, y: centerY - CGFloat(height) * 0.055,
        width: CGFloat(width), height: CGFloat(height) * 0.11
      ))
      graphics.addPath(path)
      graphics.setStrokeColor(CGColor(red: 0.12, green: 0.09, blue: 0.08, alpha: fade * 0.55))
      graphics.setLineWidth(max(2, CGFloat(width) * 0.009))
      graphics.strokePath()
      graphics.addPath(path)
      graphics.setStrokeColor(CGColor(red: 0.98, green: 0.52, blue: 0.52, alpha: fade))
      graphics.setLineWidth(max(1, CGFloat(width) * 0.005))
      graphics.strokePath()
    }
    for event in active {
      guard let index = visibleAssetIds.firstIndex(of: event.assetId) else { continue }
      let target = targets[index]
      let size = min(target.width, target.height)
      let center = CGPoint(x: target.maxX - size * 0.18, y: target.midY)
      let alpha = CGFloat(1 - Double(sample - event.destinationStartSample) / 9_600)
      let tint = index.isMultiple(of: 2)
        ? CGColor(red: 0.94, green: 0.36, blue: 0.34, alpha: alpha)
        : CGColor(red: 0.72, green: 0.55, blue: 0.98, alpha: alpha)
      for angle in [-0.6, 0.0, 0.6] {
        let dx = CGFloat(cos(angle))
        let dy = CGFloat(sin(angle))
        let start = CGPoint(
          x: center.x + dx * size * 0.04,
          y: center.y + dy * size * 0.04
        )
        let end = CGPoint(
          x: center.x + dx * size * 0.11,
          y: center.y + dy * size * 0.11
        )
        graphics.move(to: start)
        graphics.addLine(to: end)
        graphics.setStrokeColor(CGColor(red: 1, green: 1, blue: 1, alpha: alpha))
        graphics.setLineWidth(size * 0.019)
        graphics.strokePath()
        graphics.move(to: start)
        graphics.addLine(to: end)
        graphics.setStrokeColor(tint)
        graphics.setLineWidth(size * 0.011)
        graphics.strokePath()
      }
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

  private var cachedImages: [Int: CGImage] = [:]
  private var recentFrames: [Int] = []
  private var cachedBytes = 0
  private let maximumCachedBytes = 24 * 1024 * 1024

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
    if let image = cachedImages[index] {
      recentFrames.removeAll { $0 == index }
      recentFrames.append(index)
      return image
    }
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
    let cost = generated.image.bytesPerRow * generated.image.height
    while !recentFrames.isEmpty && (recentFrames.count >= 8 || cachedBytes + cost > maximumCachedBytes) {
      let oldest = recentFrames.removeFirst()
      if let image = cachedImages.removeValue(forKey: oldest) {
        cachedBytes -= image.bytesPerRow * image.height
      }
    }
    if cost <= maximumCachedBytes {
      cachedImages[index] = generated.image
      recentFrames.append(index)
      cachedBytes += cost
    }
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
