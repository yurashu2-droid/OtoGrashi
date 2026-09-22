import AVFoundation
import Foundation

struct MediaValidationReport: Codable, Equatable {
  let durationUs: Int64
  let decodedFrameCount: Int
  let width: Int
  let height: Int
  let audioTrackCount: Int
  let audioDurationUs: Int64
  let firstAudibleSample: Int
  let videoCueFrame: Int?
  let videoCueTimeUs: Int64?
  let audioVideoDeltaUs: Int64?
}

struct MediaValidator {
  func validate(
    url: URL,
    expectedWidth: Int,
    expectedHeight: Int,
    expectedOnsetSample: Int?,
    expectedVideoCueFrame: Int? = nil
  ) async throws -> MediaValidationReport {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration)
    let durationUs = CMTimeConvertScale(
      duration,
      timescale: 1_000_000,
      method: .roundHalfAwayFromZero
    ).value
    let videoTracks = try await asset.loadTracks(withMediaType: .video)
    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
    guard videoTracks.count == 1, audioTracks.count == 1 else {
      throw VideoRenderError.sourceReadFailed
    }
    let naturalSize = try await videoTracks[0].load(.naturalSize)
    let transform = try await videoTracks[0].load(.preferredTransform)
    let audioTimeRange = try await audioTracks[0].load(.timeRange)
    let audioDurationUs = CMTimeConvertScale(
      audioTimeRange.duration,
      timescale: 1_000_000,
      method: .roundHalfAwayFromZero
    ).value
    let transformed = naturalSize.applying(transform)
    let width = Int(abs(transformed.width).rounded())
    let height = Int(abs(transformed.height).rounded())
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(
      track: videoTracks[0],
      outputSettings: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
      ]
    )
    guard reader.canAdd(output) else { throw VideoRenderError.sourceReadFailed }
    reader.add(output)
    guard reader.startReading() else { throw VideoRenderError.sourceReadFailed }
    var frames = 0
    var cueScores: [(frame: Int, timeUs: Int64, score: Int)] = []
    while let sample = output.copyNextSampleBuffer() {
      guard CMTimeCompare(
        CMSampleBufferGetPresentationTimeStamp(sample),
        CMTime(value: CMTimeValue(frames), timescale: 30)
      ) == 0 else { throw VideoRenderError.sourceReadFailed }
      if expectedVideoCueFrame != nil, frames < 30,
        let pixelBuffer = CMSampleBufferGetImageBuffer(sample)
      {
        cueScores.append((
          frame: frames,
          timeUs: CMTimeConvertScale(
            CMSampleBufferGetPresentationTimeStamp(sample),
            timescale: 1_000_000,
            method: .roundHalfAwayFromZero
          ).value,
          score: brightPixelScore(pixelBuffer)
        ))
      }
      frames += 1
    }
    guard reader.status == .completed else { throw VideoRenderError.sourceReadFailed }

    let range = try NativePCMReader().trackRange(url: url)
    let decoded = try NativePCMReader().readTimeline(
      url: url,
      startSample: range.startSample,
      durationSamples: min(ArrangementPayload.totalSamples, range.endSample - range.startSample)
    )
    guard let audibleOffset = decoded.samples.firstIndex(where: { abs($0) > 0.001 }) else {
      throw VideoRenderError.sourceReadFailed
    }
    let firstAudible = range.startSample + audibleOffset
    let cue = cueScores.max { left, right in left.score < right.score }
    let onsetTimeUs = Int64(firstAudible) * 1_000_000 / 48_000
    let syncDelta = cue.map { abs($0.timeUs - onsetTimeUs) }
    guard durationUs == 15_000_000,
      frames == VideoRenderer.frameCount,
      width == expectedWidth,
      height == expectedHeight,
      audioDurationUs == 15_000_000,
      expectedOnsetSample.map({ abs(firstAudible - $0) <= 1_600 }) ?? true,
      expectedVideoCueFrame.map({ cue?.frame == $0 }) ?? true,
      syncDelta.map({ $0 <= 33_334 }) ?? true
    else { throw VideoRenderError.sourceReadFailed }
    return MediaValidationReport(
      durationUs: durationUs,
      decodedFrameCount: frames,
      width: width,
      height: height,
      audioTrackCount: audioTracks.count,
      audioDurationUs: audioDurationUs,
      firstAudibleSample: firstAudible,
      videoCueFrame: cue?.frame,
      videoCueTimeUs: cue?.timeUs,
      audioVideoDeltaUs: syncDelta
    )
  }

  private func brightPixelScore(_ buffer: CVPixelBuffer) -> Int {
    CVPixelBufferLockBaseAddress(buffer, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
    let width = CVPixelBufferGetWidth(buffer)
    let height = CVPixelBufferGetHeight(buffer)
    let rowBytes = CVPixelBufferGetBytesPerRow(buffer)
    let bytes = base.assumingMemoryBound(to: UInt8.self)
    var score = 0
    for y in stride(from: 0, to: height, by: 8) {
      for x in stride(from: 0, to: width, by: 8) {
        let offset = y * rowBytes + x * 4
        if bytes[offset] > 220, bytes[offset + 1] > 220, bytes[offset + 2] > 220 {
          score += 1
        }
      }
    }
    return score
  }
}
