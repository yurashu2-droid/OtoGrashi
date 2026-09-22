import AVFoundation
import CoreMedia
import Foundation

struct PCMReadResult: Equatable {
  let samples: [Float]
  let requestedRange: Range<Int>
  let coveredRanges: [Range<Int>]

  var coveredSampleCount: Int {
    coveredRanges.reduce(0) { $0 + $1.count }
  }
}

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
  ) throws -> PCMReadResult {
    guard cancellation?.isCancelled != true else { throw AudioRenderError.cancelled }
    let (endSample, overflow) = startSample.addingReportingOverflow(durationSamples)
    guard startSample >= 0, durationSamples > 0, !overflow else {
      throw AudioRenderError.sourceOutOfBounds
    }
    let requestedRange = startSample..<endSample
    let nativeRange = try trackRange(url: url)
    let decodeStart = max(requestedRange.lowerBound, nativeRange.startSample)
    let decodeEnd = min(requestedRange.upperBound, nativeRange.endSample)
    guard decodeEnd > decodeStart else { throw AudioRenderError.sourceOutOfBounds }

    let asset = AVURLAsset(url: url)
    guard let track = asset.tracks(withMediaType: .audio).first else {
      throw AudioRenderError.readFailed
    }
    let reader = try AVAssetReader(asset: asset)
    reader.timeRange = CMTimeRange(
      start: CMTime(
        value: CMTimeValue(decodeStart),
        timescale: CMTimeScale(Self.sampleRate)
      ),
      duration: CMTime(
        value: CMTimeValue(decodeEnd - decodeStart),
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
      AVLinearPCMIsNonInterleaved: false,
    ]
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { throw AudioRenderError.readFailed }
    reader.add(output)
    guard reader.startReading() else { throw AudioRenderError.readFailed }

    var samples = Array(repeating: Float(0), count: durationSamples)
    var coveredRanges: [Range<Int>] = []
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
      let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
      let bufferStart = try Self.sampleIndex(presentationTime)
      let duration = CMSampleBufferGetDuration(sampleBuffer)
      let mappedValueCount: Int
      if duration.isNumeric, duration.value >= 0 {
        let bufferEnd = try Self.sampleIndex(CMTimeAdd(presentationTime, duration))
        mappedValueCount = min(values.count, max(0, bufferEnd - bufferStart))
      } else {
        mappedValueCount = values.count
      }
      if let covered = place(
        values: Array(values.prefix(mappedValueCount)),
        bufferStartSample: bufferStart,
        requestedRange: requestedRange,
        into: &samples
      ) {
        Self.merge(covered, into: &coveredRanges)
      }
    }
    if reader.status == .failed { throw AudioRenderError.readFailed }
    guard !coveredRanges.isEmpty else { throw AudioRenderError.sourceOutOfBounds }
    return PCMReadResult(
      samples: samples,
      requestedRange: requestedRange,
      coveredRanges: coveredRanges
    )
  }

  func place(
    values: [Float],
    bufferStartSample: Int,
    requestedRange: Range<Int>,
    into timeline: inout [Float]
  ) -> Range<Int>? {
    let (bufferEnd, overflow) = bufferStartSample.addingReportingOverflow(values.count)
    guard !overflow else { return nil }
    let coveredStart = max(bufferStartSample, requestedRange.lowerBound)
    let coveredEnd = min(bufferEnd, requestedRange.upperBound)
    guard coveredEnd > coveredStart else { return nil }
    let sourceOffset = coveredStart - bufferStartSample
    let destinationOffset = coveredStart - requestedRange.lowerBound
    let count = coveredEnd - coveredStart
    guard destinationOffset >= 0,
      destinationOffset + count <= timeline.count,
      sourceOffset >= 0,
      sourceOffset + count <= values.count
    else { return nil }
    timeline.replaceSubrange(
      destinationOffset..<(destinationOffset + count),
      with: values[sourceOffset..<(sourceOffset + count)]
    )
    return coveredStart..<coveredEnd
  }

  private static func merge(_ range: Range<Int>, into ranges: inout [Range<Int>]) {
    if let last = ranges.last, range.lowerBound <= last.upperBound {
      ranges[ranges.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
    } else {
      ranges.append(range)
    }
  }

  private static func sampleIndex(_ time: CMTime) throws -> Int {
    guard time.isNumeric, time.value >= 0 else { throw AudioRenderError.readFailed }
    let converted = CMTimeConvertScale(
      time,
      timescale: CMTimeScale(sampleRate),
      method: .roundHalfAwayFromZero
    )
    guard converted.isNumeric, let value = Int(exactly: converted.value) else {
      throw AudioRenderError.readFailed
    }
    return value
  }
}
