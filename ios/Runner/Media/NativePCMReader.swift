import AVFoundation
import CoreMedia
import Foundation

struct NativePCMReader {
  static let sampleRate = 48_000

  struct TrackRange: Equatable {
    let startSample: Int
    let durationSamples: Int
    let endSample: Int
  }

  func trackRange(url: URL) throws -> TrackRange {
    let asset = AVURLAsset(url: url)
    guard let track = asset.tracks(withMediaType: .audio).first else {
      throw AudioRenderError.readFailed
    }
    let timeRange = track.timeRange
    let start = try Self.sampleIndex(timeRange.start)
    let duration = try Self.sampleIndex(timeRange.duration)
    let (end, overflow) = start.addingReportingOverflow(duration)
    guard start >= 0, duration > 0, !overflow else {
      throw AudioRenderError.readFailed
    }
    return TrackRange(startSample: start, durationSamples: duration, endSample: end)
  }

  func readTimeline(
    url: URL,
    startSample: Int,
    durationSamples: Int,
    cancellation: CancellationToken? = nil
  ) throws -> [Float] {
    let range = try trackRange(url: url)
    let offset = startSample - range.startSample
    guard offset >= 0 else { throw AudioRenderError.sourceOutOfBounds }
    return try readTrackOffset(
      url: url,
      offsetSamples: offset,
      durationSamples: min(durationSamples, max(0, range.durationSamples - offset)),
      cancellation: cancellation
    )
  }

  func readTrackOffset(
    url: URL,
    offsetSamples: Int,
    durationSamples: Int,
    cancellation: CancellationToken? = nil
  ) throws -> [Float] {
    guard offsetSamples >= 0, durationSamples > 0 else {
      throw AudioRenderError.sourceOutOfBounds
    }
    let asset = AVURLAsset(url: url)
    guard let track = asset.tracks(withMediaType: .audio).first else {
      throw AudioRenderError.readFailed
    }
    let trackRange = track.timeRange
    let requestedStart = CMTimeAdd(
      trackRange.start,
      CMTime(value: CMTimeValue(offsetSamples), timescale: CMTimeScale(Self.sampleRate))
    )
    let reader = try AVAssetReader(asset: asset)
    reader.timeRange = CMTimeRange(
      start: requestedStart,
      duration: CMTime(
        value: CMTimeValue(durationSamples),
        timescale: CMTimeScale(Self.sampleRate)
      )
    )
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: Self.sampleRate,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleavedKey: false,
    ]
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { throw AudioRenderError.readFailed }
    reader.add(output)
    guard reader.startReading() else { throw AudioRenderError.readFailed }

    var samples: [Float] = []
    samples.reserveCapacity(durationSamples)
    while let sampleBuffer = output.copyNextSampleBuffer() {
      if cancellation?.isCancelled == true {
        reader.cancelReading()
        throw AudioRenderError.cancelled
      }
      guard let block = CMSampleBufferGetDataBuffer(sampleBuffer) else { continue }
      let byteCount = CMBlockBufferGetDataLength(block)
      let valueCount = min(CMSampleBufferGetNumSamples(sampleBuffer), byteCount / 4)
      guard valueCount > 0 else { continue }
      var values = [Float](repeating: 0, count: valueCount)
      let status = values.withUnsafeMutableBytes { storage in
        CMBlockBufferCopyDataBytes(
          block,
          atOffset: 0,
          dataLength: valueCount * MemoryLayout<Float>.size,
          destination: storage.baseAddress!
        )
      }
      guard status == kCMBlockBufferNoErr else { throw AudioRenderError.readFailed }
      let remaining = durationSamples - samples.count
      samples.append(contentsOf: values.prefix(max(0, remaining)))
      if samples.count >= durationSamples { break }
    }
    if reader.status == .failed { throw AudioRenderError.readFailed }
    return samples
  }

  private static func sampleIndex(_ time: CMTime) throws -> Int {
    guard time.isNumeric, time.value >= 0 else { throw AudioRenderError.readFailed }
    let converted = CMTimeConvertScale(
      time,
      timescale: CMTimeScale(sampleRate),
      method: .roundTowardZero
    )
    guard converted.isNumeric, let value = Int(exactly: converted.value) else {
      throw AudioRenderError.readFailed
    }
    return value
  }
}
