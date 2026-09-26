import AVFoundation
import CoreImage
import CoreText
import Foundation
import Vision

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
  let totalSamples: Int
  let layout: VideoLayoutPayload
  let clipCrops: [ClipCropPayload]
  let captions: [VideoCaptionPayload]
  let events: [VideoSceneEventPayload]
  let effects: VideoEffectsPayload
  let clipNames: [String: String]

  private enum CodingKeys: String, CodingKey {
    case schemaVersion, totalSamples, layout, clipCrops, captions, events, effects, clipNames
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
    totalSamples = try container.decodeIfPresent(Int.self, forKey: .totalSamples) ?? 720_000
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
    guard schemaVersion == 1, [720_000, 1_440_000].contains(totalSamples),
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
      events.last?.destinationEndSample == totalSamples
    else { throw VideoRenderError.unsupportedContract }
    for (index, event) in events.enumerated() {
      guard event.destinationStartSample >= 0,
        event.durationSamples > 0,
        event.destinationEndSample <= totalSamples,
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
        end <= totalSamples
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
    guard video.totalSamples == arrangement.totalSamples, schemaVersion == 1, !operationId.isEmpty, !projectId.isEmpty, revision >= 0,
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
    let outputFrames = request.arrangement.totalSamples / 1_600
    let requiredIds = Set(request.arrangement.videoEvents.map(\.assetId))
      .union(request.video.events.flatMap(\.assetIds))
    guard requiredIds.allSatisfy({ assets[$0] != nil }) else {
      throw VideoRenderError.missingAsset
    }
    let audioURL = outputURL.deletingPathExtension().appendingPathExtension("caf")
    defer { try? FileManager.default.removeItem(at: audioURL) }
    let audioReport = try await audioRenderer.render(
      arrangement: request.arrangement,
      assets: assets,
      outputURL: audioURL,
      cancellation: cancellation
    )
    videoRenderDiagnostic("VIDEO_STAGE audio_complete")
    try checkCancellation(cancellation)
    let waveformPeaks: [CGFloat]
    if request.video.layout == .buildUp || request.arrangement.performanceMode != "natural" {
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
    let mad = request.arrangement.performanceMode == "mad"
      ? MadDirector(request: request, peaks: audioReport.eventPeaks) : nil
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
      for frame in 0..<outputFrames {
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
          if let mad {
            try await mad.draw(frame: frame, width: dimensions.width, height: dimensions.height,
              into: buffer, context: context) { event, sample in
              try await madImage(event, sample, request: request, providers: providers)
            }
          } else {
            try await drawFrame(
              frame,
              request: request,
              providers: providers,
              waveformPeaks: waveformPeaks,
              eventPeaks: audioReport.eventPeaks,
              into: buffer,
              width: dimensions.width,
              height: dimensions.height
            )
          }
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
        if frame == 0 || frame % 30 == 0 || frame == outputFrames - 1 {
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
      writer.endSession(atSourceTime: CMTime(value: CMTimeValue(request.arrangement.totalSamples), timescale: 48_000))
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
        frameCount: outputFrames,
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

  /// The picture a MAD event shows at an output sample, cropped like any clip.
  private func madImage(_ event: MadVideoEvent, _ sample: Int, request: VideoRenderRequestPayload,
                        providers: [String: SourceProvider]) async throws -> CIImage {
    guard let provider = providers[event.assetId] else { throw VideoRenderError.missingAsset }
    let requested = CMTime(value: CMTimeValue(event.sourceSample(sample)), timescale: 48_000)
    let last = CMTimeMaximum(.zero, provider.duration - CMTime(value: 1, timescale: 600))
    let time = CMTimeMinimum(last, CMTimeMaximum(.zero, requested))
    var image = CIImage(cgImage: try await provider.image(at: time))
    if let crop = request.video.clipCrops.first(where: { $0.assetId == event.assetId })?.crop {
      image = image.cropped(to: CGRect(x: image.extent.minX + CGFloat(crop.x) * image.extent.width,
        y: image.extent.minY + CGFloat(1 - crop.y - crop.height) * image.extent.height,
        width: CGFloat(crop.width) * image.extent.width, height: CGFloat(crop.height) * image.extent.height))
      image = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
    }
    return image
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
    eventPeaks: [[Float]],
    into buffer: CVPixelBuffer,
    width: Int,
    height: Int
  ) async throws {
    let sample = frame * 1_600
    if request.arrangement.performanceMode != "natural" {
      try await drawPerformanceFrame(frame, request: request, providers: providers,
        waveformPeaks: waveformPeaks, eventPeaks: eventPeaks, into: buffer, width: width, height: height)
      return
    }
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

  // All performance pictures are driven by the same bounded audio events.
  // Inactive pads hold a real frame; only sounding pads bounce and emit rings.
  private struct PerformanceCard {
    let event: VideoEventPayload
    let playing: Bool
    let rect: CGRect
    let index: Int
    let age: Int
    let peaks: [Float]
    let voices: Int
  }

  static func performanceRects(count: Int, mode: String, width: CGFloat, height: CGFloat) -> [CGRect] {
    guard count > 0 else { return [] }
    let margin = width * 0.06
    let gap = width * 0.035
    let top = height * 0.79
    let usableHeight = height * 0.62
    let columns = mode == "mosaic" ? 3 : count > 6 ? 3 : count == 1 ? 1 : 2
    let rows = mode == "mosaic" ? max(3, (count + 2) / 3) : (count + columns - 1) / columns
    let cellWidth = (width - 2 * margin - CGFloat(columns - 1) * gap) / CGFloat(columns)
    let cellHeight = (usableHeight - CGFloat(rows - 1) * gap) / CGFloat(rows)
    return (0..<count).map { i in
      let w = mode == "vinyl" ? min(cellWidth, cellHeight - width * 0.045) : cellWidth
      let h = mode == "mosaic" ? min(cellHeight, w * 1.34) : mode == "vinyl" ? w : min(cellHeight, w * 1.14)
      return CGRect(x: margin + CGFloat(i % columns) * (cellWidth + gap) + (cellWidth - w) / 2,
        y: top - CGFloat(i / columns) * (cellHeight + gap) - h, width: w, height: h)
    }
  }

  private func drawPerformanceFrame(_ frame: Int, request: VideoRenderRequestPayload,
    providers: [String: SourceProvider], waveformPeaks: [CGFloat], eventPeaks: [[Float]], into buffer: CVPixelBuffer,
    width: Int, height: Int) async throws {
    let sample = frame * 1600
    let mode = request.arrangement.performanceMode
    let w = CGFloat(width), h = CGFloat(height)
    let bounds = CGRect(x: 0, y: 0, width: w, height: h)
    let sorted = request.arrangement.videoEvents.enumerated().sorted {
      $0.element.destinationStartSample == $1.element.destinationStartSample
        ? $0.offset < $1.offset
        : $0.element.destinationStartSample < $1.element.destinationStartSample
    }.map(\.element)
    func key(_ e: VideoEventPayload) -> String { "\(e.assetId)#\(e.partIndex ?? 0)" }
    var keys: [String] = []
    for event in sorted where !keys.contains(key(event)) { keys.append(key(event)) }
    let active = sorted.filter { sample >= $0.destinationStartSample && sample < $0.destinationStartSample + $0.durationSamples }
    let activeKeys = Set(active.map(key))
    // Protect audible cards when a large bank needs pagination.
    if keys.count > 18 {
      let live = keys.filter(activeKeys.contains)
      keys = live + keys.filter { !activeKeys.contains($0) }.prefix(max(0, 18 - live.count))
    }
    var rects = Self.performanceRects(count: keys.count, mode: mode, width: w, height: h)
    if mode == "voiceLead", let phrase = request.arrangement.events.last(where: {
      $0.treatment == "phrase" && sample >= $0.destinationStartSample && sample < $0.destinationStartSample + $0.durationSamples
    }), let main = keys.firstIndex(of: "\(phrase.assetId)#\(phrase.partIndex ?? 0)") {
      // The speaker is foreground, but every backing source remains visible.
      let others = keys.indices.filter { $0 != main }
      rects[main] = CGRect(x: w * 0.06, y: h * 0.36, width: w * 0.88, height: h * 0.43)
      for (position, index) in others.enumerated() {
        let columns = max(1, min(4, others.count)), row = position / max(1, min(4, others.count))
        let rows = max(1, (others.count + columns - 1) / columns)
        let gap = w * 0.02
        let size = min(w * 0.2, (h * 0.22 - CGFloat(rows - 1) * gap) / CGFloat(rows))
        rects[index] = CGRect(x: w * 0.06 + CGFloat(position % columns) * w * 0.225,
          y: h * 0.32 - CGFloat(row + 1) * size - CGFloat(row) * gap, width: size, height: size)
      }
    }
    var canvas = CIImage(color: CIColor(red: 0.035, green: 0.04, blue: 0.065)).cropped(to: bounds)
    var cards: [PerformanceCard] = []
    for (index, identity) in keys.enumerated() {
      let all = sorted.filter { key($0) == identity }
      let live = active.filter { key($0) == identity }
      let historical = all.last { $0.destinationStartSample <= sample }
      if (mode == "mosaic" || mode == "loopStation"), historical == nil { continue }
      guard let event = live.last ?? historical ?? all.first, let provider = providers[event.assetId] else { continue }
      let audioIndex = request.arrangement.videoEvents.firstIndex(of: event)
      let peaks = audioIndex.flatMap { $0 < eventPeaks.count ? eventPeaks[$0] : nil } ?? []
      let localFrame = max(0, sample - event.destinationStartSample) / 1600
      let audible = peaks.isEmpty || (localFrame < peaks.count && peaks[localFrame] > 0.0001)
      let isPlaying = !live.isEmpty && audible
      let age = isPlaying ? sample - event.destinationStartSample : 48000
      // Beat-aware punch inside a long word, without rewinding its video.
      let curve = audioIndex.flatMap { request.arrangement.events[$0].pitchSteps } ?? []
      let onset = curve.last { $0.offsetSamples <= age }?.offsetSamples ?? 0
      let punch = isPlaying ? CGFloat(max(0, 1 - Double(age - onset) / 6500)) : 0
      let baseRect = rects[index]
      let factor: CGFloat = mode == "sampler" || mode == "neonTune" ? 0.94 + 0.06 * punch : 1
      var tile = baseRect.insetBy(dx: baseRect.width * (1 - factor) / 2, dy: baseRect.height * (1 - factor) / 2)
      tile.origin.y += punch * w * 0.009
      let timeSample = event.destinationStartSample + min(max(0, sample - event.destinationStartSample), event.durationSamples - 1)
      let sourceTime = Self.sourceTime(assetId: event.assetId, sample: timeSample, events: [event], duration: provider.duration)
      var image = CIImage(cgImage: try await provider.image(at: sourceTime))
      if let crop = request.video.clipCrops.first(where: { $0.assetId == event.assetId })?.crop {
        image = image.cropped(to: CGRect(x: image.extent.minX + CGFloat(crop.x) * image.extent.width,
          y: image.extent.minY + CGFloat(1 - crop.y - crop.height) * image.extent.height,
          width: CGFloat(crop.width) * image.extent.width, height: CGFloat(crop.height) * image.extent.height))
      }
      if event.isMirrored && mode != "vinyl" {
        image = image.transformed(by: CGAffineTransform(a: -1, b: 0, c: 0, d: 1, tx: image.extent.midX * 2, ty: 0))
      }
      let scale = max(tile.width / image.extent.width, tile.height / image.extent.height)
      image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
      image = image.transformed(by: CGAffineTransform(translationX: tile.midX - image.extent.midX, y: tile.midY - image.extent.midY))
      if mode == "vinyl" {
        // Rotation follows source time, so the disc also reverses on scratches.
        let angle = CGFloat(CMTimeGetSeconds(sourceTime) * 2.4)
        let rotate = CGAffineTransform(translationX: tile.midX, y: tile.midY)
          .rotated(by: angle).translatedBy(x: -tile.midX, y: -tile.midY)
        image = image.transformed(by: rotate)
      } else if mode == "neonTune" && isPlaying {
        image = image.clampedToExtent().applyingFilter("CITwirlDistortion", parameters: [
          "inputCenter": CIVector(x: tile.midX, y: tile.midY),
          "inputRadius": min(tile.width, tile.height) * 0.75,
          "inputAngle": sin(Double(sample) / 48000 * 4) * 0.24
        ]).applyingFilter("CIHueAdjust", parameters: ["inputAngle": Double(sample) / 48000 * 0.9])
      }
      image = image.cropped(to: tile)
      if !isPlaying { image = image.applyingFilter("CIColorControls", parameters: ["inputSaturation": 0.25, "inputBrightness": -0.16]) }
      if mode == "vinyl" {
        let radius = min(tile.width, tile.height) / 2
        guard let mask = CIFilter(name: "CIRadialGradient", parameters: [
          "inputCenter": CIVector(x: tile.midX, y: tile.midY), "inputRadius0": radius - 1,
          "inputRadius1": radius, "inputColor0": CIColor.white, "inputColor1": CIColor.black
        ])?.outputImage else { throw VideoRenderError.writerFailed }
        canvas = image.applyingFilter("CIBlendWithMask", parameters: ["inputBackgroundImage": canvas, "inputMaskImage": mask]).cropped(to: bounds)
      } else { canvas = image.composited(over: canvas) }
      cards.append(PerformanceCard(event: event, playing: isPlaying, rect: tile, index: index, age: age, peaks: peaks, voices: live.count))
    }
    context.render(canvas, to: buffer, bounds: bounds, colorSpace: CGColorSpace(name: CGColorSpace.itur_709))
    try drawPerformanceOverlay(cards, frame: frame, request: request, peaks: waveformPeaks,
      into: buffer, width: width, height: height)
    try drawCaptions(request.video.captions.filter { sample >= $0.destinationStartSample && sample < $0.destinationStartSample + $0.durationSamples }, into: buffer, width: width, height: height)
  }

  private func drawPerformanceOverlay(_ cards: [PerformanceCard], frame: Int,
    request: VideoRenderRequestPayload, peaks: [CGFloat], into buffer: CVPixelBuffer,
    width: Int, height: Int) throws {
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer), let g = CGContext(data: base,
      width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
    else { throw VideoRenderError.writerFailed }
    let w = CGFloat(width), h = CGFloat(height), mode = request.arrangement.performanceMode
    let palette: [CGColor] = [CGColor(red: 0.7, green: 1, blue: 0.28, alpha: 1),
      CGColor(red: 1, green: 0.39, blue: 0.59, alpha: 1), CGColor(red: 0.35, green: 0.85, blue: 1, alpha: 1),
      CGColor(red: 1, green: 0.76, blue: 0.27, alpha: 1)]
    func text(_ string: String, _ x: CGFloat, _ y: CGFloat, _ size: CGFloat, _ color: CGColor) {
      let attrs: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("HiraginoSans-W6" as CFString, size, nil), NSAttributedString.Key(kCTForegroundColorAttributeName as String): color]
      let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attrs))
      g.textPosition = CGPoint(x: x, y: y); CTLineDraw(line, g)
    }
    let white = CGColor(gray: 1, alpha: 1)
    let title = ["mosaic": "MEMORY WALL", "vinyl": "VOICE VINYL", "sampler": "DAILY SAMPLER", "voiceLead": "VOICE & MELODY", "neonTune": "RAINBOW TUNE", "loopStation": "LOOP STATION"][mode] ?? "OTOGRASHI"
    text("OTOGRASHI / 128 BPM", w * 0.06, h * 0.937, w * 0.024, palette[0])
    text(title, w * 0.06, h * 0.871, w * 0.06, white)
    let seconds = request.arrangement.totalSamples / 48000
    text("\(cards.filter(\.playing).count) VOICES  ·  \(String(format: "%02d", frame / 30)) / \(seconds)s", w * 0.06, h * 0.833, w * 0.025, CGColor(gray: 0.67, alpha: 1))
    for card in cards {
      let color = palette[card.index % palette.count], r = card.rect
      g.setStrokeColor(card.playing ? color : CGColor(gray: 0.35, alpha: 0.5))
      g.setLineWidth(w * (card.playing ? 0.006 : 0.002))
      if mode == "vinyl" {
        g.strokeEllipse(in: r)
        for k in [0.06, 0.12, 0.18] { g.strokeEllipse(in: r.insetBy(dx: r.width * k, dy: r.height * k)) }
        g.setFillColor(CGColor(gray: 0.04, alpha: 0.9)); g.fillEllipse(in: r.insetBy(dx: r.width * 0.35, dy: r.height * 0.35))
        g.setFillColor(color); g.fillEllipse(in: r.insetBy(dx: r.width * 0.465, dy: r.height * 0.465))
      } else { g.stroke(r) }
      let title = request.video.clipNames[card.event.assetId] ?? "SOUND \(card.index + 1)"
      let part = card.event.partIndex ?? 0
      let name = part > 0 ? "\(title) ·\(part + 1)" : title
      g.saveGState(); g.clip(to: CGRect(x: r.minX, y: r.minY - w * 0.04, width: r.width, height: w * 0.05))
      text(String(name.prefix(14)), r.minX + 2, r.minY - w * 0.033, min(w * 0.027, r.width * 0.09), card.playing ? white : CGColor(gray: 0.55, alpha: 1)); g.restoreGState()
      if card.playing && (mode == "sampler" || mode == "neonTune" || mode == "loopStation") {
        let radius = min(r.width, r.height) * 0.44
        // Each pad follows its OWN post-fade rendered samples, not another voice in the mix.
        for k in 0..<40 {
          let a = Double(k) * Double.pi * 2 / 40
          let envelopeFrame = card.age / 1600 + k / 5 - 4
          let level = card.peaks.isEmpty ? CGFloat(0) : CGFloat(card.peaks[max(0, min(card.peaks.count - 1, envelopeFrame))])
          let length = w * 0.01 + min(1, level) * w * 0.038
          let x = CGFloat(cos(a)), y = CGFloat(sin(a))
          g.move(to: CGPoint(x: r.midX + x * radius, y: r.midY + y * radius))
          g.addLine(to: CGPoint(x: r.midX + x * (radius + length), y: r.midY + y * (radius + length)))
        }
        g.setLineWidth(w * 0.003); g.strokePath()
      }
      if card.voices > 1 {
        text("×\(card.voices)", r.maxX - w * 0.055, r.maxY - w * 0.037, w * 0.029, color)
      }
      if card.playing && card.event.isReversed {
        text("REVERSE", r.minX + 5, r.maxY - w * 0.037, w * 0.026, palette[1])
      }
    }
    let beat = frame * 1600 / 22500
    for index in 0..<16 {
      let x = w * 0.06 + CGFloat(index) * w * 0.055
      g.setFillColor(index == beat % 16 ? palette[0] : CGColor(gray: 0.3, alpha: 0.8))
      g.fill(CGRect(x: x, y: h * 0.082, width: w * 0.038, height: h * 0.008))
    }
    text("RECORDED LIFE. REMIXED.", w * 0.06, h * 0.046, w * 0.025, CGColor(gray: 0.7, alpha: 1))
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
      frameCapacity: AVAudioFrameCount(min(file.length, 1_440_000))
    ) else { throw VideoRenderError.sourceReadFailed }
    try file.read(into: buffer, frameCount: buffer.frameCapacity)
    guard let samples = buffer.floatChannelData?[0] else {
      throw VideoRenderError.sourceReadFailed
    }
    var peaks = Array(repeating: CGFloat(0), count: max(1, (Int(buffer.frameLength) + 1599) / 1600))
    for sample in 0..<Int(buffer.frameLength) {
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
    guard !active.isEmpty || (waveformEvent != nil && !waveformPeaks.isEmpty)
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
    if let waveformEvent, !waveformPeaks.isEmpty {
      let fade = CGFloat(1 - Double(sample - waveformEvent.destinationStartSample) / 28_800)
      let centerY = CGFloat(height) * (visibleAssetIds.count > 1 ? 0.45 : 0.22)
      let step = CGFloat(width) * 0.88 / 48
      let currentFrame = sample / 1_600
      let path = CGMutablePath()
      for bar in 0..<48 {
        let frame = currentFrame + bar - 24
        let peak = waveformPeaks[max(0, min(waveformPeaks.count - 1, frame))]
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

// MARK: - MAD video director

/// One sound of a MAD arrangement as the picture sees it.
struct MadVideoEvent {
  let index: Int
  let assetId: String
  let clip: Int
  let start: Int
  let end: Int
  let role: String
  let pitched: Bool
  let sourceStart: Int
  let sourceSpan: Int
  let reverse: Bool
  let rate: Double?
  let glide: Double?
  let scratch: Double?
  let scratchPeriod: Int?
  let peaks: [Float]
  let peakMax: Float

  func active(_ sample: Int) -> Bool { sample >= start && sample < end }

  /// Loudness of this event alone at `sample`, 0...1 of its own peak.
  func level(_ sample: Int) -> Float {
    let i = (sample - start) / 1_600
    guard i >= 0, i < peaks.count, peakMax > 0 else { return 0 }
    return peaks[i] / peakMax
  }

  /// The source time shown at output `sample`: the same positions the sound
  /// reads, so a scratch rocks the face and a finished sound holds its frame.
  func sourceSample(_ sample: Int) -> Int {
    let offset = min(max(0, sample - start), max(0, end - start - 1))
    var position: Double
    if rate != nil || glide != nil || scratch != nil {
      position = SoundEventPayload.motionPosition(at: offset, count: max(1, end - start), rate: rate,
        glide: glide, scratch: scratch, scratchPeriod: scratchPeriod)
      if reverse { position = Double(sourceSpan - 1) - position }
    } else {
      position = Double(EverydayAudioDSP.sourceOffset(outputOffset: offset,
        sourceCount: max(1, sourceSpan), reverse: reverse))
    }
    return sourceStart + min(max(0, Int(position)), max(0, sourceSpan - 1))
  }
}

struct MadMask {
  let image: CIImage
  let box: CGRect
  let rowsFilled: Double
  let coverage: Double
}

enum MadShot: String {
  case full, flip, stutter, mirror, burst, pile, cutout, sticker
}

/// Chooses a shot per bar along the song's energy, draws it with the sounding
/// clips only, and adds the moments (a strip of stills for repeats, opening
/// and ending cards, the picture side of master effects).
final class MadDirector {
  static let backdrops: [(CGFloat, CGFloat, CGFloat)] = [
    (0.97, 0.75, 0.80), (0.77, 0.89, 0.95), (0.94, 0.91, 0.80), (0.80, 0.93, 0.84),
  ]
  static let colors: [CGColor] = [
    CGColor(red: 0.94, green: 0.44, blue: 0.42, alpha: 1),
    CGColor(red: 0.61, green: 0.52, blue: 0.94, alpha: 1),
    CGColor(red: 0.95, green: 0.66, blue: 0.23, alpha: 1),
    CGColor(red: 0.35, green: 0.71, blue: 0.59, alpha: 1),
    CGColor(red: 0.34, green: 0.63, blue: 0.90, alpha: 1),
    CGColor(red: 0.90, green: 0.47, blue: 0.75, alpha: 1),
  ]
  static let beat = 22_500
  static let bar = 90_000

  let events: [MadVideoEvent]
  /// Quiet plays behind the melody: shown as a corner sticker, never as the
  /// main picture.
  let backing: [MadVideoEvent]
  let assetIds: [String]
  let names: [String]
  let total: Int
  let seed: Int
  let title: String
  let effects: [MasterEffectPayload]
  let plan: [(shot: MadShot, start: Int, end: Int, energy: String)]
  let runs: [[MadVideoEvent]]
  let heard: [Int]
  private var masks: [String: MadMask?] = [:]
  private var subjects: [Int: Bool] = [:]

  init(request: VideoRenderRequestPayload, peaks: [[Float]]) {
    let arrangement = request.arrangement
    assetIds = arrangement.sourceAssetIds
    names = assetIds.enumerated().map { request.video.clipNames[$1] ?? "音\($0 + 1)" }
    total = arrangement.totalSamples
    seed = arrangement.seed
    title = arrangement.songTitle ?? "なんでもない日の音"
    effects = arrangement.masterEffects
    var built: [MadVideoEvent] = []
    for (index, event) in arrangement.events.enumerated() {
      let eventPeaks = index < peaks.count ? peaks[index] : []
      built.append(MadVideoEvent(index: index, assetId: event.assetId,
        clip: arrangement.sourceAssetIds.firstIndex(of: event.assetId) ?? 0,
        start: event.destinationStartSample, end: event.destinationStartSample + event.durationSamples,
        role: event.role ?? "phrase", pitched: event.targetMidiNote != nil,
        sourceStart: event.sourceStartSample, sourceSpan: event.effectiveSourceDurationSamples,
        reverse: event.isReversed, rate: event.rate, glide: event.glide, scratch: event.scratch,
        scratchPeriod: event.scratchPeriod, peaks: eventPeaks, peakMax: eventPeaks.max() ?? 0))
    }
    events = built.filter { $0.role != "backing" }
    backing = built.filter { $0.role == "backing" }
    heard = Array(Set(built.map(\.clip))).sorted()
    runs = Self.repeatRuns(events)
    plan = Self.planShots(total: arrangement.totalSamples, seed: arrangement.seed,
      sections: arrangement.sections, soloBars: Set(backing.map { $0.start / Self.bar }))
  }

  // MARK: plan

  static func repeatRuns(_ events: [MadVideoEvent]) -> [[MadVideoEvent]] {
    let repeatable: Set<String> = ["chop", "fx", "echo", "phrase"]
    var runs: [[MadVideoEvent]] = []
    var open: [String: Int] = [:]
    for e in events.sorted(by: { $0.start < $1.start })
    where repeatable.contains(e.role) && !e.pitched {
      let key = "\(e.clip)#\(e.sourceStart)"
      if let r = open[key], let last = runs[r].last, e.start - last.start <= beat * 3 / 4 {
        runs[r].append(e)
      } else {
        open[key] = runs.count
        runs.append([e])
      }
    }
    return runs.filter { $0.count >= 2 }
  }

  /// Shots that show one picture over the whole frame; a backing sticker
  /// only ever sits on one of these.
  static let solo: [MadShot] = [.full, .flip, .stutter]

  static func planShots(total: Int, seed: Int, sections: [SongSectionPayload], soloBars: Set<Int> = [])
    -> [(shot: MadShot, start: Int, end: Int, energy: String)]
  {
    var rng = SeededRandom(seed: UInt64(bitPattern: Int64(seed)) &+ 0x9E37)
    let pools: [String: [MadShot]] = [
      "calm": [.full, .flip, .sticker, .cutout],
      "mid": [.mirror, .stutter, .pile, .flip, .cutout, .sticker],
      "high": [.burst, .mirror, .stutter, .burst],
    ]
    let bleed: Set<MadShot> = [.full, .flip, .stutter, .mirror, .burst]
    let bars = total / bar
    var plan: [(shot: MadShot, start: Int, end: Int, energy: String)] = []
    var used: Set<MadShot> = []
    var last: MadShot?
    var b = 0
    while b < bars {
      let p = Double(b) / Double(bars)
      var energy = p < 0.25 ? "calm" : p < 0.6 ? "mid" : "high"
      if b == bars - 1 { energy = "high" }
      for section in sections where section.fromBar <= b && b < section.toBar {
        energy = section.energy
      }
      var choices = (pools[energy] ?? [.full]).filter {
        $0 != last && !($0 == .pile && (b + 2 > bars - 1 || soloBars.contains(b + 1)))
      }
      if soloBars.contains(b) { choices = solo.filter { $0 != last } }
      if b == 0 { choices = choices.filter { bleed.contains($0) } }
      if choices.isEmpty { choices = [.full] }
      let fresh = choices.filter { !used.contains($0) }
      let pool = fresh.isEmpty ? choices : fresh
      let shot = pool[rng.next(pool.count)]
      used.insert(shot)
      let span = shot == .pile ? 2 : 1
      plan.append((shot, b * bar, min(bars, b + span) * bar, energy))
      b += span
      last = shot
    }
    if !plan.contains(where: { $0.shot == .burst }), let tail = plan.last, !soloBars.contains(tail.start / bar) {
      plan[plan.count - 1] = (.burst, tail.start, tail.end, tail.energy)
    }
    return plan
  }

  // MARK: picking what to show

  func voices(_ s: Int) -> [MadVideoEvent] {
    events.filter { $0.active(s) }.sorted { ($0.start, $0.index) < ($1.start, $1.index) }
  }

  func lastOnset(_ s: Int, _ where_: (MadVideoEvent) -> Bool = { _ in true }) -> MadVideoEvent? {
    var best: MadVideoEvent?
    for e in events where e.start <= s && where_(e) {
      if best == nil || e.start >= best!.start { best = e }
    }
    return best
  }

  /// Effects lead, then a spoken phrase, then the melody (held through its
  /// small gaps for up to a beat), then bass, then whatever sounds.
  func lead(_ s: Int) -> MadVideoEvent {
    let live = voices(s)
    if let fx = live.last(where: { $0.role == "fx" }) { return fx }
    if let p = live.last(where: { $0.role == "phrase" }) { return p }
    if let m = live.last(where: { $0.role == "melody" }) { return m }
    if let held = lastOnset(s, { $0.role == "melody" || $0.role == "phrase" }), s - held.end < Self.beat {
      return held
    }
    if let b = live.last(where: { $0.role == "bass" }) { return b }
    if let any = live.last { return any }
    return lastOnset(s) ?? events.first!
  }

  // MARK: drawing

  func draw(frame: Int, width: Int, height: Int, into buffer: CVPixelBuffer, context: CIContext,
            image: (MadVideoEvent, Int) async throws -> CIImage) async throws {
    let W = CGFloat(width), H = CGFloat(height)
    var s = frame * 1_600
    // a tape stop slows the picture with the sound
    for fx in effects where fx.type == "tapestop" && s >= fx.startSample && s < fx.startSample + fx.durationSamples {
      let u = Double(s - fx.startSample) / Double(fx.durationSamples)
      s = fx.startSample + Int(Double(fx.durationSamples) * (u - u * u / 2))
    }
    let current = plan.first(where: { $0.start <= s && s < $0.end }) ?? plan[plan.count - 1]
    let canvasRect = CGRect(x: 0, y: 0, width: W, height: H)
    var canvas: CIImage
    var overlays: [(CGContext) -> Void] = []
    let longRun = runs.contains { $0.count >= 4 && $0[0].start <= s && s < $0[$0.count - 1].end + 14_400 }
    if longRun && (current.shot == .cutout || current.shot == .sticker) {
      canvas = CIImage(color: backdrop()).cropped(to: canvasRect)
      canvas = try await strip(s, over: canvas, dim: false, W: W, H: H, image: image)
    } else {
      switch current.shot {
      case .full, .flip, .stutter:
        canvas = try await single(s, shot: current.shot, segmentStart: current.start, W: W, H: H,
          image: image, overlays: &overlays)
      case .mirror:
        canvas = try await mirror(s, W: W, H: H, image: image, overlays: &overlays)
      case .burst:
        canvas = try await burst(s, segmentStart: current.start, W: W, H: H, image: image, overlays: &overlays)
      case .pile:
        canvas = try await pile(s, segment: (current.start, current.end), W: W, H: H, image: image, overlays: &overlays)
      case .cutout:
        canvas = try await cutoutShot(s, W: W, H: H, image: image, overlays: &overlays)
      case .sticker:
        canvas = try await sticker(s, W: W, H: H, image: image, overlays: &overlays)
      }
      if current.shot != .cutout && current.shot != .sticker {
        canvas = try await strip(s, over: canvas, dim: true, W: W, H: H, image: image)
      }
      if Self.solo.contains(current.shot) && !longRun {
        canvas = try await backingStickers(s, over: canvas, W: W, H: H, image: image, overlays: &overlays)
      }
    }
    canvas = pictureEffects(canvas, sample: frame * 1_600, W: W, H: H)
    // a louder section opens on a white flash
    if let index = plan.firstIndex(where: { $0.start <= s && s < $0.end }), index > 0,
      rank(plan[index].energy) > rank(plan[index - 1].energy), s - plan[index].start < 2_880 {
      let a = 0.6 * (1 - Double(s - plan[index].start) / 2_880)
      canvas = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: CGFloat(a))).cropped(to: canvasRect)
        .composited(over: canvas)
    }
    let t = Double(frame) / 30
    let ending = Double(total) / 48_000 - 1.3
    if t >= ending {
      canvas = try await endCard(canvas, t: t - ending, W: W, H: H, image: image)
      overlays = [{ g in self.endText(g, t: t - ending, W: W, H: H) }]
    }
    context.render(canvas.cropped(to: canvasRect), to: buffer, bounds: canvasRect,
      colorSpace: CGColorSpace(name: CGColorSpace.itur_709))
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let base = CVPixelBufferGetBaseAddress(buffer),
      let g = CGContext(data: base, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
    else { throw VideoRenderError.writerFailed }
    for overlay in overlays { overlay(g) }
    if t < 1.6 { openingText(g, t: t, W: W, H: H) }
  }

  private func rank(_ energy: String) -> Int { energy == "high" ? 2 : energy == "mid" ? 1 : 0 }

  private func backdrop() -> CIColor {
    let c = Self.backdrops[abs(seed) % Self.backdrops.count]
    return CIColor(red: c.0, green: c.1, blue: c.2)
  }

  /// Top-left rect to Core Image coordinates.
  private func ci(_ r: CGRect, _ H: CGFloat) -> CGRect {
    CGRect(x: r.minX, y: H - r.maxY, width: r.width, height: r.height)
  }

  /// Fill `rect` (top-left coordinates) with the picture, faces kept high.
  private func cover(_ picture: CIImage, _ rect: CGRect, H: CGFloat, zoom: CGFloat = 1,
                     mirror: Bool = false, flip: Bool = false, dx: CGFloat = 0) -> CIImage {
    let target = ci(rect, H)
    let e = picture.extent
    guard e.width > 0, e.height > 0 else { return CIImage.empty() }
    let scale = max(target.width / e.width, target.height / e.height) * max(1, zoom)
    let shown = CGSize(width: target.width / scale, height: target.height / scale)
    let cx = min(max(e.midX + dx * e.width, e.minX + shown.width / 2), e.maxX - shown.width / 2)
    let focusFromTop: CGFloat = 0.42
    let cy = min(max(e.maxY - e.height * focusFromTop, e.minY + shown.height / 2), e.maxY - shown.height / 2)
    var t = CGAffineTransform(translationX: -cx, y: -cy)
      .concatenating(CGAffineTransform(scaleX: scale * (mirror ? -1 : 1), y: scale * (flip ? -1 : 1)))
      .concatenating(CGAffineTransform(translationX: target.midX, y: target.midY))
    if picture.extent.isInfinite { t = .identity }
    return picture.transformed(by: t).cropped(to: target)
  }

  private func dimmed(_ image: CIImage, soft: Bool) -> CIImage {
    image.applyingFilter("CIColorControls", parameters: [
      "inputSaturation": soft ? 0.65 : 0.3, "inputBrightness": soft ? -0.1 : -0.28,
    ])
  }

  private func lit(_ image: CIImage, _ level: Float) -> CIImage {
    level > 0 ? image.applyingFilter("CIColorControls", parameters: ["inputBrightness": 0.12 * Double(level)]) : image
  }

  private func punch(_ age: Int, _ amount: CGFloat = 0.14, _ length: Int = 5_760) -> CGFloat {
    1 + amount * max(0, 1 - CGFloat(age) / CGFloat(length))
  }

  private func panel(_ e: MadVideoEvent, _ s: Int, _ rect: CGRect, H: CGFloat, zoom: CGFloat = 1,
                     mirror: Bool = false, flip: Bool = false, dx: CGFloat = 0, soft: Bool = false,
                     hold: Int = 0, image: (MadVideoEvent, Int) async throws -> CIImage) async throws -> CIImage {
    let live = e.active(s) || (hold > 0 && s >= e.end && s - e.end < hold)
    let picture = try await image(e, s)
    let shot = cover(picture, rect, H: H, zoom: zoom * (1 + 0.04 * CGFloat(live ? e.level(s) : 0)),
      mirror: mirror, flip: flip, dx: dx)
    return live ? lit(shot, e.level(s)) : dimmed(shot, soft: soft)
  }

  // MARK: shots

  private func single(_ s: Int, shot: MadShot, segmentStart: Int, W: CGFloat, H: CGFloat,
                      image: (MadVideoEvent, Int) async throws -> CIImage,
                      overlays: inout [(CGContext) -> Void]) async throws -> CIImage {
    let lead = lead(s)
    let full = CGRect(x: 0, y: 0, width: W, height: H)
    var zoom = punch(s - lead.start)
    var mirror = false
    var dx: CGFloat = 0
    switch shot {
    case .flip:
      let notes = events.filter { $0.start >= segmentStart && $0.start <= s && ($0.role == "melody" || $0.role == "phrase") && $0.pitched }.count
      mirror = notes % 2 == 1
      dx = 0.04 * CGFloat(notes % 3 - 1)
      zoom = 1.08 * punch(s - lead.start, 0.1)
    case .stutter:
      let steps = Set(events.filter { $0.start >= segmentStart && $0.start <= s }.map { $0.start / (Self.beat / 2) }).count
      zoom = (1 + 0.12 * CGFloat(steps % 4)) * punch(s - lead.start, 0.08)
    default:
      break
    }
    let picture = try await panel(lead, s, full, H: H, zoom: zoom, mirror: mirror, dx: dx, soft: true,
      hold: Self.beat / 2, image: image)
    let count = voices(s).filter { $0.clip == lead.clip }.count
    overlays.append { g in self.label(g, lead, s, CGRect(x: 0, y: 0, width: W, height: H), H: H, count: count) }
    return picture.composited(over: CIImage(color: .black).cropped(to: ci(full, H)))
  }

  private func mirror(_ s: Int, W: CGFloat, H: CGFloat, image: (MadVideoEvent, Int) async throws -> CIImage,
                      overlays: inout [(CGContext) -> Void]) async throws -> CIImage {
    let lead = lead(s)
    let same = voices(s).filter { $0.clip == lead.clip }
    let repeats = repeatIndex(lead)
    let zoom = 1.06 * punch(s - lead.start, 0.1)
    let flips = [(false, false), (true, false), (false, true), (true, true)]
    var canvas = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
    if same.count >= 3 {
      for (i, origin) in [(0, 0), (1, 0), (0, 1), (1, 1)].enumerated() {
        let rect = CGRect(x: CGFloat(origin.0) * W / 2, y: CGFloat(origin.1) * H / 2, width: W / 2, height: H / 2)
        let f = flips[i]
        canvas = try await panel(lead, s, rect, H: H, zoom: zoom, mirror: f.0, flip: f.1, image: image).composited(over: canvas)
      }
    } else if same.count == 2 {
      for i in 0..<2 {
        let rect = CGRect(x: CGFloat(i) * W / 2, y: 0, width: W / 2, height: H)
        let f = flips[(repeats + i) % 4]
        canvas = try await panel(lead, s, rect, H: H, zoom: zoom, mirror: f.0, flip: f.1, image: image).composited(over: canvas)
      }
    } else {
      let f = flips[repeats % 4]
      canvas = try await panel(lead, s, CGRect(x: 0, y: 0, width: W, height: H), H: H, zoom: zoom,
        mirror: f.0, flip: f.1, soft: true, hold: Self.beat / 2, image: image).composited(over: canvas)
    }
    overlays.append { g in self.label(g, lead, s, CGRect(x: 0, y: 0, width: W, height: H), H: H, count: same.count) }
    return canvas
  }

  private func repeatIndex(_ e: MadVideoEvent) -> Int {
    var n = 0
    var previous = e
    while let before = lastOnset(previous.start - 1, { $0.clip == e.clip }),
      before.sourceStart == e.sourceStart, previous.start - before.start <= Self.beat * 2, n < 16 {
      n += 1
      previous = before
    }
    return n
  }

  private func layout(_ n: Int, W: CGFloat, H: CGFloat) -> [CGRect] {
    guard n > 1 else { return [CGRect(x: 0, y: 0, width: W, height: H)] }
    let rows = n <= 3 ? n : n <= 6 ? (n + 1) / 2 : 3
    var rects: [CGRect] = []
    for r in 0..<rows {
      let k = n / rows + (r < n % rows ? 1 : 0)
      for c in 0..<k {
        rects.append(CGRect(x: CGFloat(c) * W / CGFloat(k), y: CGFloat(r) * H / CGFloat(rows),
          width: W / CGFloat(k), height: H / CGFloat(rows)))
      }
    }
    return rects
  }

  /// One picture per clip heard so far in the bar; the grid grows and resets
  /// on the downbeat, and each clip keeps its place.
  private func burst(_ s: Int, segmentStart: Int, W: CGFloat, H: CGFloat,
                     image: (MadVideoEvent, Int) async throws -> CIImage,
                     overlays: inout [(CGContext) -> Void]) async throws -> CIImage {
    let barStart = segmentStart + (s - segmentStart) / Self.bar * Self.bar
    let window = events.filter { $0.start >= barStart && $0.start <= s }
    guard !window.isEmpty else {
      var ignored: [(CGContext) -> Void] = []
      return try await single(s, shot: .full, segmentStart: segmentStart, W: W, H: H, image: image, overlays: &ignored)
    }
    var clips: [Int] = []
    for e in window.sorted(by: { $0.start < $1.start }) where !clips.contains(e.clip) { clips.append(e.clip) }
    if clips.count > 4 { clips = Array(clips.suffix(4)) }
    let rects = layout(clips.count, W: W, H: H)
    var canvas = CIImage(color: .black).cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
    var shown: [(MadVideoEvent, CGRect, Int)] = []
    for (clip, rect) in zip(clips, rects) {
      let live = voices(s).filter { $0.clip == clip }
      let e = live.last ?? window.filter { $0.clip == clip }.max(by: { $0.start < $1.start })!
      canvas = try await panel(e, s, rect, H: H, zoom: live.isEmpty ? 1 : punch(s - e.start, 0.08, 4_800),
        image: image).composited(over: canvas)
      shown.append((e, rect, live.count))
    }
    overlays.append { g in
      g.setStrokeColor(CGColor(gray: 0, alpha: 1))
      g.setLineWidth(3)
      for (_, rect, _) in shown { g.stroke(self.ci(rect, H)) }
      for (e, rect, count) in shown {
        if e.active(s) {
          let width = 2 + 7 * CGFloat(e.level(s))
          g.setStrokeColor(Self.colors[e.clip % Self.colors.count])
          g.setLineWidth(width)
          g.stroke(self.ci(rect, H).insetBy(dx: width / 2, dy: width / 2))
        }
        self.label(g, e, s, rect, H: H, count: max(1, count))
      }
    }
    return canvas
  }

  /// A new photo card for every sound in the stretch, piling up on paper;
  /// finished ones freeze and fade, and the pile clears at the end.
  private func pile(_ s: Int, segment: (Int, Int), W: CGFloat, H: CGFloat,
                    image: (MadVideoEvent, Int) async throws -> CIImage,
                    overlays: inout [(CGContext) -> Void]) async throws -> CIImage {
    var canvas = CIImage(color: CIColor(red: 0.98, green: 0.95, blue: 0.90)).cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
    var spawned = events.filter { $0.start >= segment.0 && $0.start <= s && $0.role != "hat" && $0.role != "kick" }
      .sorted { $0.start < $1.start }
    if spawned.isEmpty || spawned[0].start > segment.0 + 2_400,
      let carry = lastOnset(segment.0 - 1, { $0.role == "melody" || $0.role == "phrase" }) {
      spawned.insert(carry, at: 0)
    }
    var rng = SeededRandom(seed: UInt64(segment.0 / Self.bar) &* 101 &+ 3)
    let layouts = (0..<(spawned.count + 1)).map { _ in
      (CGFloat(rng.unit()) * 0.64 + 0.18, CGFloat(rng.unit()) * 0.6 + 0.2, (CGFloat(rng.unit()) - 0.5) * 18)
    }
    let cards = Array(spawned.enumerated().suffix(10))
    let clearing = s > segment.1 - 5_760
    var newestMelodic: (MadVideoEvent, CGPoint, CGFloat)?
    for (rank, (idx, e)) in cards.enumerated() {
      let big: CGFloat = ["phrase": 0.86, "melody": 0.66, "bass": 0.5, "chop": 0.46][e.role] ?? 0.38
      let depth = CGFloat(cards.count - 1 - rank)
      let age = CGFloat(max(0, s - e.start)) / 48_000
      let pop = CGFloat(Self.overshoot(Double(age) / 0.25))
      let w = W * big * (1 - 0.04 * depth) * pop
      let h = w * 1.25
      guard w > 4 else { continue }
      let (fx, fy, rot) = layouts[idx]
      var cx = fx * W
      let cy = fy * H
      if clearing { cx += CGFloat(s - (segment.1 - 5_760)) / 5_760 * W * (idx % 2 == 0 ? -1 : 1) }
      let live = e.active(s)
      let photoRect = CGRect(x: cx - w / 2, y: cy - h / 2, width: w, height: h)
      var photo = try await panel(e, live ? s : e.end - 1_600, photoRect, H: H, mirror: idx % 3 == 2, image: image)
      if !live { photo = dimmed(photo, soft: false) }
      let edge = max(6, w * 0.035)
      let frameRect = ci(photoRect, H).insetBy(dx: -edge, dy: -edge)
      var card = photo.composited(over: CIImage(color: .white).cropped(to: frameRect))
      let tilt = (rot + (1 - CGFloat(Self.easeOut(Double(age) / 0.2))) * 10) * .pi / 180
      let centre = CGPoint(x: frameRect.midX, y: frameRect.midY)
      card = card.transformed(by: CGAffineTransform(translationX: -centre.x, y: -centre.y)
        .concatenating(CGAffineTransform(rotationAngle: tilt))
        .concatenating(CGAffineTransform(translationX: centre.x, y: centre.y)))
      canvas = card.composited(over: canvas)
      if rank == cards.count - 1 && e.role != "hat" && e.role != "kick" && e.role != "snare" {
        newestMelodic = (e, CGPoint(x: cx, y: cy + h / 2 + 40), w)
      }
    }
    if let newest = newestMelodic {
      let (e, point, _) = newest
      overlays.append { g in
        self.text(g, self.names[e.clip], at: point, size: 46, color: CGColor(red: 0.14, green: 0.11, blue: 0.10, alpha: 1),
          H: H, font: "HiraMaruProN-W4", centred: true)
      }
    }
    return canvas
  }

  // MARK: cut-outs

  private func mask(_ e: MadVideoEvent, _ s: Int, picture: CIImage, largest: Bool = false) -> MadMask? {
    let key = "\(e.assetId)#\(e.sourceSample(s) / 1_600)\(largest ? "L" : "")"
    if let cached = masks[key] { return cached }
    let made = Self.foregroundMask(picture, largest: largest)
    if masks.count > 160 { masks.removeAll() }
    masks[key] = made
    return made
  }

  /// Pixels above half in a Vision mask, sampled every 8th pixel.
  static func maskPixels(_ buffer: CVPixelBuffer) -> Int {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
    let row = CVPixelBufferGetBytesPerRow(buffer)
    var on = 0
    for y in stride(from: 0, to: h, by: 8) {
      let line = base.advanced(by: y * row).assumingMemoryBound(to: Float32.self)
      for x in stride(from: 0, to: w, by: 8) where line[x] > 0.5 { on += 1 }
    }
    return on
  }

  /// largest: keep only the biggest subject, so a small sticker never carries
  /// a stray piece of someone at the edge of the frame.
  static func foregroundMask(_ picture: CIImage, largest: Bool = false) -> MadMask? {
    let context = CIContext(options: [.cacheIntermediates: false])
    guard let cg = context.createCGImage(picture, from: picture.extent) else { return nil }
    let handler = VNImageRequestHandler(cgImage: cg, options: [:])
    let request = VNGenerateForegroundInstanceMaskRequest()
    do {
      try handler.perform([request])
      guard let observation = request.results?.first else { return nil }
      var instances = observation.allInstances
      if largest, instances.count > 1 {
        var best: (instance: Int, pixels: Int)?
        for instance in instances {
          let single = try observation.generateScaledMaskForImage(forInstances: IndexSet(integer: instance), from: handler)
          let pixels = maskPixels(single)
          if best == nil || pixels > best!.pixels { best = (instance, pixels) }
        }
        if let best { instances = IndexSet(integer: best.instance) }
      }
      let buffer = try observation.generateScaledMaskForImage(forInstances: instances, from: handler)
      CVPixelBufferLockBaseAddress(buffer, .readOnly)
      defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
      let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
      guard w > 0, h > 0, let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
      let row = CVPixelBufferGetBytesPerRow(buffer)
      var minX = w, maxX = -1, minY = h, maxY = -1, on = 0, rowsOn = 0, samples = 0
      for y in stride(from: 0, to: h, by: 4) {
        let line = base.advanced(by: y * row).assumingMemoryBound(to: Float32.self)
        var any = false
        for x in stride(from: 0, to: w, by: 4) {
          samples += 1
          if line[x] > 0.5 {
            on += 1
            any = true
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
          }
        }
        if any { rowsOn += 1 }
      }
      guard maxX >= minX, maxY >= minY else { return nil }
      let image = CIImage(cvPixelBuffer: buffer).transformed(by: CGAffineTransform(
        translationX: picture.extent.minX, y: picture.extent.minY))
      // pixel rows run top-down; Core Image runs bottom-up
      let box = CGRect(x: picture.extent.minX + CGFloat(minX), y: picture.extent.minY + CGFloat(h - 1 - maxY),
        width: CGFloat(maxX - minX + 4), height: CGFloat(maxY - minY + 4))
      let boxRows = Double(max(1, (maxY - minY) / 4 + 1))
      return MadMask(image: image, box: box, rowsFilled: Double(rowsOn) / boxRows,
        coverage: Double(on) / Double(max(1, samples)))
    } catch {
      return nil
    }
  }

  private func hasSubject(_ clip: Int, image: (MadVideoEvent, Int) async throws -> CIImage) async -> Bool {
    if let known = subjects[clip] { return known }
    var votes = 0, count = 0
    for e in (events + backing).filter({ $0.clip == clip }).prefix(3) {
      guard let picture = try? await image(e, e.start) else { continue }
      count += 1
      if let m = mask(e, e.start, picture: picture), m.coverage > 0.05, m.coverage < 0.9, m.rowsFilled > 0.6 {
        votes += 1
      }
    }
    let result = count > 0 && votes * 2 >= count
    subjects[clip] = result
    return result
  }

  /// The subject on transparency with a white edge, scaled to `height`.
  private func cutout(_ e: MadVideoEvent, _ s: Int, height: CGFloat, maxWidth: CGFloat, outline: CGFloat,
                      largest: Bool = false,
                      image: (MadVideoEvent, Int) async throws -> CIImage) async throws -> CIImage? {
    let picture = try await image(e, s)
    guard let m = mask(e, s, picture: picture, largest: largest), m.rowsFilled >= 0.6 else { return nil }
    let alpha = m.image.cropped(to: m.box)
    var subject = picture.cropped(to: m.box).applyingFilter("CIBlendWithMask", parameters: [
      kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: alpha,
    ])
    let scale = min(height / m.box.height, maxWidth / m.box.width)
    if outline > 0 {
      let grown = alpha.applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": outline / scale])
      let white = CIImage(color: .white).cropped(to: m.box.insetBy(dx: -outline / scale - 2, dy: -outline / scale - 2))
        .applyingFilter("CIBlendWithMask", parameters: [
          kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: grown,
        ])
      subject = subject.composited(over: white)
    }
    let moved = subject.transformed(by: CGAffineTransform(translationX: -m.box.minX, y: -m.box.minY)
      .concatenating(CGAffineTransform(scaleX: scale, y: scale)))
    return moved
  }

  /// A clip playing quietly behind the melody pops up as a small sticker in
  /// the bottom-right corner, sways with its own level and pops away after.
  private func backingStickers(_ s: Int, over canvas: CIImage, W: CGFloat, H: CGFloat,
                               image: (MadVideoEvent, Int) async throws -> CIImage,
                               overlays: inout [(CGContext) -> Void]) async throws -> CIImage {
    var out = canvas
    let k = W / 720
    let linger = 7_200  // 0.15 s to pop away
    for e in backing where s >= e.start && s < e.end + linger {
      let age = Double(s - e.start) / 48_000
      let scale = s < e.end ? Self.overshoot(age / 0.3) : 1 - Self.easeOut(Double(s - e.end) / Double(linger))
      guard scale > 0.02 else { continue }
      let at = min(s, e.end - 1)
      var piece: CIImage?
      if await hasSubject(e.clip, image: image) {
        piece = try await cutout(e, at, height: H * 0.24, maxWidth: W * 0.34, outline: 8 * k, largest: true,
          image: image)
      }
      if piece == nil { piece = try await photoCard(e, at, height: H * 0.2, H: H, image: image) }
      guard var sticker = piece, !sticker.extent.isEmpty else { continue }
      let level = s < e.end ? Double(e.level(s)) : 0
      let tilt = CGFloat(-6 + 5 * level * sin(age * 9)) * .pi / 180
      let e0 = sticker.extent
      sticker = sticker.transformed(by: CGAffineTransform(translationX: -e0.midX, y: -e0.midY)
        .concatenating(CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        .concatenating(CGAffineTransform(rotationAngle: tilt)))
      let r = sticker.extent
      let bottom = 170 * k  // Core Image y of the sticker's lower edge
      sticker = sticker.transformed(by: CGAffineTransform(translationX: W - 36 * k - r.maxX, y: bottom - r.minY))
      let shadow = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 0.35)).cropped(to: sticker.extent)
        .applyingFilter("CIBlendWithAlphaMask", parameters: [
          kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: sticker,
        ])
        .applyingGaussianBlur(sigma: 10 * k)
        .transformed(by: CGAffineTransform(translationX: 6 * k, y: -10 * k))
      out = sticker.composited(over: shadow.composited(over: out))
      if scale > 0.6 {
        let name = names[e.clip]
        let color = Self.colors[e.clip % Self.colors.count]
        let centre = CGPoint(x: sticker.extent.midX, y: H - sticker.extent.minY)  // top-left coordinates
        overlays.append { g in self.namePill(g, name, centre: centre, color: color, k: k, H: H) }
      }
    }
    return out
  }

  /// A coloured pill with the clip's name, hanging from the bottom of a sticker.
  private func namePill(_ g: CGContext, _ name: String, centre: CGPoint, color: CGColor, k: CGFloat, H: CGFloat) {
    let size = 24 * k
    let attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("HiraginoSans-W6" as CFString, size, nil),
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: name, attributes: attributes))
    let tw = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    let pill = ci(CGRect(x: centre.x - tw / 2 - 14 * k, y: centre.y - 6 * k, width: tw + 28 * k, height: 36 * k), H)
    g.setFillColor(color.copy(alpha: 0.92) ?? color)
    g.addPath(CGPath(roundedRect: pill, cornerWidth: 18 * k, cornerHeight: 18 * k, transform: nil))
    g.fillPath()
    g.textPosition = CGPoint(x: pill.midX - tw / 2, y: pill.midY - size * 0.35)
    CTLineDraw(line, g)
  }

  private func photoCard(_ e: MadVideoEvent, _ s: Int, height: CGFloat, H: CGFloat,
                         image: (MadVideoEvent, Int) async throws -> CIImage) async throws -> CIImage {
    let w = height * 0.75
    let rect = CGRect(x: 0, y: 0, width: w, height: height)
    let picture = try await image(e, s)
    let photo = cover(picture, rect, H: height)
    let edge = max(5, height * 0.03)
    return photo.composited(over: CIImage(color: .white).cropped(to: CGRect(x: -edge, y: -edge,
      width: w + 2 * edge, height: height + 2 * edge)))
  }

  private func place(_ piece: CIImage, centre: CGPoint, bottom: CGFloat? = nil, H: CGFloat, tilt: CGFloat = 0) -> CIImage {
    let e = piece.extent
    var t = CGAffineTransform(translationX: -e.midX, y: -e.midY)
    if tilt != 0 { t = t.concatenating(CGAffineTransform(rotationAngle: tilt * .pi / 180)) }
    let y = bottom.map { H - $0 + e.height / 2 } ?? (H - centre.y)
    return piece.transformed(by: t.concatenating(CGAffineTransform(translationX: centre.x, y: y)))
  }

  /// Flat ground, the figure drops in when it comes back, and each repeat of
  /// its sound within a beat adds a clone to its right, behind it.
  private func cutoutShot(_ s: Int, W: CGFloat, H: CGFloat, image: (MadVideoEvent, Int) async throws -> CIImage,
                          overlays: inout [(CGContext) -> Void]) async throws -> CIImage {
    var canvas = CIImage(color: backdrop()).cropped(to: CGRect(x: 0, y: 0, width: W, height: H))
    let lead = lead(s)
    if voices(s).isEmpty && s - lead.end > 5_760 { return canvas }
    let beatStart = s / Self.beat * Self.beat
    var hits = events.filter { $0.clip == lead.clip && $0.start >= beatStart && $0.start <= s && !$0.pitched }
      .sorted { $0.start < $1.start }
    if hits.isEmpty { hits = [lead] }
    hits = Array(hits.prefix(5))
    var appeared = s
    while appeared > s - 96_000, !voices(appeared - 1_600).isEmpty { appeared -= 1_600 }
    let fall = Self.dropIn(Double(s - appeared) / 48_000, height: H * 0.8)
    let subject = await hasSubject(lead.clip, image: image)
    var pieces: [(Int, CIImage)] = []
    for (i, e) in hits.enumerated() {
      let at = e.active(s) ? s : e.start
      var piece: CIImage?
      if subject {
        piece = try await cutout(e, at, height: H * 0.8, maxWidth: W * 0.75, outline: 8, image: image)
      } else {
        piece = try await photoCard(e, at, height: H * 0.55, H: H, image: image)
      }
      if let piece { pieces.append((i, piece)) }
    }
    for (i, piece) in pieces.reversed() {
      let x = W * 0.36 + CGFloat(i) * piece.extent.width * 0.25
      canvas = place(piece, centre: CGPoint(x: x, y: 0), bottom: H * 0.99 + fall, H: H).composited(over: canvas)
    }
    let name = names[lead.clip]
    overlays.append { g in
      for (j, ch) in name.prefix(10).enumerated() {
        self.text(g, String(ch), at: CGPoint(x: W * 0.9, y: H * 0.36 + CGFloat(j) * H * 0.028), size: W * 0.036,
          color: CGColor(gray: 1, alpha: 0.92), H: H, font: "HiraMaruProN-W4", centred: true)
      }
    }
    return canvas
  }

  /// On each beat with a hit the subject is lifted out as a white-edged
  /// sticker over blurred scenery from another sound; then its real
  /// surroundings rise from the bottom and close around it.
  private func sticker(_ s: Int, W: CGFloat, H: CGFloat, image: (MadVideoEvent, Int) async throws -> CIImage,
                       overlays: inout [(CGContext) -> Void]) async throws -> CIImage {
    let lead = lead(s)
    guard await hasSubject(lead.clip, image: image) else {
      return try await single(s, shot: .full, segmentStart: s, W: W, H: H, image: image, overlays: &overlays)
    }
    let full = CGRect(x: 0, y: 0, width: W, height: H)
    let picture = try await image(lead, s)
    let real = cover(picture, full, H: H)
    let hits = events.filter { $0.clip == lead.clip && $0.start <= s && !$0.pitched }
    let beats = Array(Set(hits.map { $0.start / Self.beat })).sorted()
    let lastBeat = beats.last ?? lead.start / Self.beat
    let hitTime = hits.filter { $0.start / Self.beat == lastBeat }.map(\.start).min() ?? lead.start
    let since = Double(s - hitTime) / 48_000
    let others = Array(Set(events.filter { $0.clip != lead.clip }.map(\.clip))).sorted()
    var canvas: CIImage
    if let otherClip = (others.isEmpty ? nil : others[beats.count % others.count]),
      let otherEvent = events.first(where: { $0.clip == otherClip }) {
      let scene = try await image(otherEvent, otherEvent.start)
      canvas = cover(scene, full, H: H, zoom: 1.08).clampedToExtent()
        .applyingFilter("CIGaussianBlur", parameters: ["inputRadius": W * 0.02])
        .cropped(to: ci(full, H))
        .applyingFilter("CIColorControls", parameters: ["inputBrightness": -0.08])
    } else {
      canvas = CIImage(color: backdrop()).cropped(to: ci(full, H))
    }
    let rise = CGFloat(Self.easeOut((since - 0.06) / 0.35))
    if rise > 0 {
      let risen = CGRect(x: 0, y: 0, width: W, height: H * rise)
      canvas = real.cropped(to: risen).composited(over: canvas)
    }
    if let m = mask(lead, s, picture: picture) {
      // the subject in its own place, pulled in from the frame edge so the
      // white edge closes all the way round
      let placed = cover(m.image, full, H: H).cropped(to: ci(full, H).insetBy(dx: 10, dy: 10))
      let grown = placed.applyingFilter("CIMorphologyMaximum", parameters: ["inputRadius": 10])
      let white = CIImage(color: .white).cropped(to: ci(full, H))
        .applyingFilter("CIBlendWithMask", parameters: [
          kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: grown,
        ])
      let subject = real.applyingFilter("CIBlendWithMask", parameters: [
        kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: placed,
      ])
      canvas = subject.composited(over: white.composited(over: canvas))
      if rise > 0 && rise < 1 {
        let line = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 0.8))
          .cropped(to: CGRect(x: 0, y: H * rise - 3, width: W, height: 6))
        canvas = line.composited(over: canvas)
      }
    }
    let count = voices(s).filter { $0.clip == lead.clip }.count
    overlays.append { g in self.label(g, lead, s, full, H: H, count: count) }
    return canvas
  }

  // MARK: moments

  /// While the same sound repeats, a still captured at each hit joins a strip.
  /// Stills keep their size and place; only the strip slides so the newest
  /// sits in the centre, each one dropping in with a little hop.
  private func strip(_ s: Int, over canvas: CIImage, dim: Bool, W: CGFloat, H: CGFloat,
                     image: (MadVideoEvent, Int) async throws -> CIImage) async throws -> CIImage {
    let active = runs.filter { $0[0].start <= s && s < $0[$0.count - 1].end + 14_400 }
    guard let run = active.max(by: { a, b in
      let la = a.filter { $0.start <= s }.map(\.start).max() ?? 0
      let lb = b.filter { $0.start <= s }.map(\.start).max() ?? 0
      return (a.count >= 4 ? 1 : 0, la, a.count) < (b.count >= 4 ? 1 : 0, lb, b.count)
    }) else { return canvas }
    var shown: [MadVideoEvent] = []
    var slots: Set<Int> = []
    for e in run where e.start <= s {
      let slot = e.start / (Self.beat / 4)
      if !slots.contains(slot) {
        slots.insert(slot)
        shown.append(e)
      }
    }
    guard shown.count >= (run.count >= 4 ? 1 : 2) else { return canvas }
    var base = dim ? canvas.applyingFilter("CIColorControls", parameters: ["inputBrightness": -0.22]) : canvas
    let size = H * 0.42
    let step = W * 0.2
    let k = shown.count - 1
    let gap = k > 0 ? max(Self.beat / 4, shown[k].start - shown[k - 1].start) : Self.beat / 4
    let glide = CGFloat(Self.easeOut(Double(s - shown[k].start) / max(1_600, min(4_800, Double(gap) * 0.8))))
    let centre = step * (CGFloat(k) - 1 + glide)
    let offset = W / 2 - centre
    let subject = await hasSubject(run[0].clip, image: image)
    for (i, e) in shown.enumerated() {
      let x = offset + CGFloat(i) * step
      guard x > -step, x < W + step else { continue }
      var piece: CIImage?
      if subject {
        piece = try await cutout(e, e.start, height: size, maxWidth: W * 0.55, outline: 8, image: image)
      }
      if piece == nil { piece = try await photoCard(e, e.start, height: size, H: H, image: image) }
      guard let still = piece else { continue }
      let later = shown.first(where: { $0.start > e.start })?.start ?? e.start + 48_000
      let duration = max(1_600, min(6_720, Int(Double(later - e.start) * 0.7)))
      let age = s - e.start
      var tilt: CGFloat = [-5, 3, -2, 5, -4][i % 5]
      var drop: CGFloat = 0
      if age < duration {
        let u = CGFloat(age) / CGFloat(duration)
        drop = -H * 0.3 * (1 - u * u)
        tilt += 10 * (1 - u) * (i % 2 == 0 ? -1 : 1)
      } else if age < duration + 4_800 {
        drop = -H * 0.025 * CGFloat(sin(Double.pi * Double(age - duration) / 4_800))
      }
      let y = H * 0.42 + (i % 2 == 0 ? -18 : 18) + drop
      base = place(still, centre: CGPoint(x: x, y: y), H: H, tilt: tilt).composited(over: base)
    }
    return base
  }

  /// The picture side of master effects.
  private func pictureEffects(_ canvas: CIImage, sample s: Int, W: CGFloat, H: CGFloat) -> CIImage {
    var out = canvas
    let rect = CGRect(x: 0, y: 0, width: W, height: H)
    for fx in effects where s >= fx.startSample && s < fx.startSample + fx.durationSamples {
      let u = CGFloat(s - fx.startSample) / CGFloat(fx.durationSamples)
      switch fx.type {
      case "tapestop":
        out = out.applyingFilter("CIColorControls", parameters: ["inputBrightness": -0.6 * Double(u * u)])
      case "sweep":
        out = out.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: ["inputRadius": W * 0.022 * pow(1 - u, 1.5)])
          .cropped(to: rect)
      case "bitcrush":
        out = out.applyingFilter("CIPixellate", parameters: ["inputScale": max(4, W / 52), kCIInputCenterKey: CIVector(x: 0, y: 0)])
          .cropped(to: rect)
      case "sidechain":
        if let kick = (fx.kickSamples ?? []).last(where: { $0 <= s }), s - kick < 9_600 {
          let z = 1 + 0.05 * (1 - CGFloat(s - kick) / 9_600)
          out = out.transformed(by: CGAffineTransform(translationX: -W / 2, y: -H / 2)
            .concatenating(CGAffineTransform(scaleX: z, y: z))
            .concatenating(CGAffineTransform(translationX: W / 2, y: H / 2))).cropped(to: rect)
        }
      case "halftime":
        let z = 1 + 0.14 * u
        out = out.transformed(by: CGAffineTransform(translationX: -W / 2, y: -H / 2)
          .concatenating(CGAffineTransform(scaleX: z, y: z))
          .concatenating(CGAffineTransform(translationX: W / 2, y: H / 2))).cropped(to: rect)
      default:
        break
      }
    }
    return out
  }

  private func endCard(_ canvas: CIImage, t: Double, W: CGFloat, H: CGFloat,
                       image: (MadVideoEvent, Int) async throws -> CIImage) async throws -> CIImage {
    let rect = CGRect(x: 0, y: 0, width: W, height: H)
    var card = CIImage(color: CIColor(red: 0.14, green: 0.11, blue: 0.10)).cropped(to: rect)
    let cw = (W - 72) / 2, ch = (H * 0.56 - 24) / 2
    for i in 0..<min(4, max(1, heard.count)) {
      let clip = heard[i % heard.count]
      guard let e = events.first(where: { $0.clip == clip }) else { continue }
      let appear = CGFloat(Self.easeOut((t - Double(i) * 0.08) / 0.2))
      guard appear > 0 else { continue }
      let x = 24 + CGFloat(i % 2) * (cw + 24)
      let y = 110 + CGFloat(i / 2) * (ch + 24) + (1 - appear) * 80
      let picture = try await image(e, e.start)
      card = cover(picture, CGRect(x: x, y: y, width: cw, height: ch), H: H).composited(over: card)
    }
    let wipe = CGFloat(Self.easeOut(t / 0.2))
    return wipe >= 1 ? card : card.cropped(to: CGRect(x: 0, y: 0, width: W, height: H * wipe)).composited(over: canvas)
  }

  // MARK: text

  private func text(_ g: CGContext, _ string: String, at point: CGPoint, size: CGFloat, color: CGColor, H: CGFloat,
                    font: String = "HiraginoSans-W6", centred: Bool = false, shadow: Bool = false) {
    let attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName(font as CFString, size, nil),
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: string, attributes: attributes))
    let width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    g.saveGState()
    if shadow { g.setShadow(offset: CGSize(width: 0, height: -3), blur: 12, color: CGColor(gray: 0, alpha: 0.55)) }
    g.textPosition = CGPoint(x: centred ? point.x - width / 2 : point.x, y: H - point.y - size * 0.35)
    CTLineDraw(line, g)
    g.restoreGState()
  }

  /// Small caption for a sounding picture: colour dot, name, live level bars.
  private func label(_ g: CGContext, _ e: MadVideoEvent, _ s: Int, _ rect: CGRect, H: CGFloat, count: Int) {
    guard e.active(s), rect.width >= 150, rect.height >= 120 else { return }
    let k = min(1, max(0.6, rect.width / 520)) * H / 1_280
    let name = names[e.clip] + (count > 1 ? "  ×\(count)" : "")
    let size = 26 * k
    let attributes: [NSAttributedString.Key: Any] = [
      NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("HiraginoSans-W6" as CFString, size, nil),
      NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1),
    ]
    let line = CTLineCreateWithAttributedString(NSAttributedString(string: name, attributes: attributes))
    let tw = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
    let ph = 46 * k, pw = tw + 96 * k
    let pill = ci(CGRect(x: rect.minX + 16 * k, y: rect.maxY - ph - 16 * k, width: pw, height: ph), H)
    g.setFillColor(CGColor(red: 0.08, green: 0.06, blue: 0.06, alpha: 0.6))
    g.addPath(CGPath(roundedRect: pill, cornerWidth: ph / 2, cornerHeight: ph / 2, transform: nil))
    g.fillPath()
    let color = Self.colors[e.clip % Self.colors.count]
    g.setFillColor(color)
    g.fillEllipse(in: CGRect(x: pill.minX + 14 * k, y: pill.midY - 7 * k, width: 14 * k, height: 14 * k))
    g.textPosition = CGPoint(x: pill.minX + 38 * k, y: pill.midY - size * 0.35)
    CTLineDraw(line, g)
    let level = CGFloat(e.level(s))
    for b in 0..<4 {
      let bh = (6 + 18 * min(1, level * (1.3 - CGFloat(b) * 0.2))) * k
      let bx = pill.minX + 44 * k + tw + CGFloat(b) * 9 * k
      g.fill(CGRect(x: bx, y: pill.midY - bh / 2, width: 5 * k, height: bh))
    }
  }

  private func openingText(_ g: CGContext, t: Double, W: CGFloat, H: CGFloat) {
    let a = CGFloat(Self.easeOut(t / 0.2) * (1 - Self.easeInOut((t - 1.3) / 0.3)))
    guard a > 0 else { return }
    let scale = W / 720
    text(g, title, at: CGPoint(x: 46 * scale, y: 118 * scale), size: 60 * scale, color: CGColor(gray: 1, alpha: a),
      H: H, shadow: true)
    text(g, heard.map { names[$0] }.joined(separator: " ・ "), at: CGPoint(x: 48 * scale, y: 186 * scale),
      size: 26 * scale, color: CGColor(gray: 1, alpha: a), H: H, shadow: true)
    g.setFillColor(Self.colors[0].copy(alpha: a) ?? Self.colors[0])
    g.fill(ci(CGRect(x: 48 * scale, y: 214 * scale, width: 72 * scale, height: 6 * scale), H))
  }

  private func endText(_ g: CGContext, t: Double, W: CGFloat, H: CGFloat) {
    let a = CGFloat(Self.easeOut((t - 0.35) / 0.25))
    guard a > 0 else { return }
    let scale = W / 720
    text(g, "オトグラシ", at: CGPoint(x: W / 2, y: H * 0.76), size: (96 + 30 * (1 - a)) * scale,
      color: CGColor(gray: 1, alpha: 1), H: H, centred: true)
    text(g, heard.map { names[$0] }.joined(separator: "・") + " でできた\(total / 48_000)秒",
      at: CGPoint(x: W / 2, y: H * 0.84), size: 28 * scale, color: Self.colors[0], H: H,
      font: "HiraMaruProN-W4", centred: true)
  }

  // MARK: easing

  static func easeOut(_ x: Double) -> Double {
    let v = min(1, max(0, x))
    return 1 - pow(1 - v, 3)
  }

  static func easeInOut(_ x: Double) -> Double {
    let v = min(1, max(0, x))
    return v * v * (3 - 2 * v)
  }

  static func overshoot(_ x: Double) -> Double {
    if x >= 1 { return 1 }
    let v = max(0, x)
    return 1 + sin(v * Double.pi * 1.6) * exp(-v * 4) * 0.35 - (1 - easeOut(v)) * 0.35
  }

  /// Falls in from above in ~0.1 s, then a small landing hop.
  static func dropIn(_ age: Double, height: CGFloat) -> CGFloat {
    if age < 0.1 {
      let u = age / 0.1
      return -height * 0.6 * CGFloat(1 - u * u)
    }
    if age < 0.22 { return -height * 0.03 * CGFloat(sin(Double.pi * (age - 0.1) / 0.12)) }
    return 0
  }
}

/// Deterministic generator so the same seed always edits the same video.
struct SeededRandom {
  private var state: UInt64
  init(seed: UInt64) { state = seed == 0 ? 0x2545F4914F6CDD1D : seed }
  mutating func nextRaw() -> UInt64 {
    state ^= state << 13
    state ^= state >> 7
    state ^= state << 17
    return state
  }
  mutating func next(_ bound: Int) -> Int { Int(nextRaw() % UInt64(max(1, bound))) }
  mutating func unit() -> Double { Double(nextRaw() % 1_000_000) / 1_000_000 }
}
