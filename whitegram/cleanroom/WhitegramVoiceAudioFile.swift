import Foundation
import AVFoundation
import OpusBinding
import AudioWaveform

public struct WhitegramVoiceProcessedAudio {
    public let data: Data
    public let duration: Double
    public let waveform: Data
}

final class WhitegramVoiceTemporaryDirectory {
    let url: URL

    init() throws {
        self.url = FileManager.default.temporaryDirectory.appendingPathComponent("whitegram-voice-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: self.url, withIntermediateDirectories: false)
    }

    deinit {
        do { try FileManager.default.removeItem(at: self.url) }
        catch { NSLog("WhitegramVoice: temporary audio cleanup failed") }
    }

    func write(_ data: Data, name: String) throws -> URL {
        let url = self.url.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        return url
    }
}

enum WhitegramVoiceAudioFile {
    static let sampleRate = 48000
    static let maximumSamples = 48000 * 60 * 20

    static func decode(_ url: URL, task: WhitegramVoiceTask) throws -> [Int16] {
        try task.check()
        if ["ogg", "opus"].contains(url.pathExtension.lowercased()) {
            return try self.decodeOgg(url, task: task)
        }
        let asset = AVURLAsset(url: url)
        return try self.decode(asset: asset, task: task)
    }

    static func decode(asset: AVAsset, task: WhitegramVoiceTask) throws -> [Int16] {
        try task.check()
        guard let track = asset.tracks(withMediaType: .audio).first else { throw WhitegramVoiceProcessingError.invalidAudio }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: self.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false
        ])
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw WhitegramVoiceProcessingError.invalidAudio }
        reader.add(output)
        task.onCancel { reader.cancelReading() }
        guard reader.startReading() else { throw WhitegramVoiceProcessingError.conversion(reader.error ?? WhitegramVoiceProcessingError.invalidAudio) }
        var samples: [Int16] = []
        while let buffer = output.copyNextSampleBuffer() {
            try task.check()
            guard let data = CMSampleBufferGetDataBuffer(buffer) else { throw WhitegramVoiceProcessingError.invalidAudio }
            let byteCount = CMBlockBufferGetDataLength(data)
            guard byteCount % 2 == 0 else { throw WhitegramVoiceProcessingError.invalidAudio }
            let count = byteCount / 2
            if count == 0 { continue }
            guard count <= self.maximumSamples - samples.count else { reader.cancelReading(); throw WhitegramVoiceProcessingError.tooLong }
            let oldCount = samples.count
            samples.append(contentsOf: repeatElement(0, count: count))
            let status = samples.withUnsafeMutableBufferPointer { destination in
                CMBlockBufferCopyDataBytes(data, atOffset: 0, dataLength: byteCount, destination: destination.baseAddress!.advanced(by: oldCount))
            }
            guard status == noErr else { throw WhitegramVoiceProcessingError.invalidAudio }
        }
        try task.check()
        guard reader.status == .completed, !samples.isEmpty else { throw WhitegramVoiceProcessingError.invalidAudio }
        return samples
    }

    private static func decodeOgg(_ url: URL, task: WhitegramVoiceTask) throws -> [Int16] {
        guard let reader = OggOpusReader(path: url.path) else { throw WhitegramVoiceProcessingError.invalidAudio }
        var block = [Int16](repeating: 0, count: 5760 * 8)
        var result: [Int16] = []
        while true {
            try task.check()
            let count = block.withUnsafeMutableBytes { reader.read($0.baseAddress!, bufSize: Int32($0.count / 2)) }
            if count == 0 { break }
            let channels = Int(reader.whitegramChannelCount)
            guard count > 0, (1 ... 8).contains(channels), Int(count) <= block.count / channels else { throw WhitegramVoiceProcessingError.invalidAudio }
            guard Int(count) <= self.maximumSamples - result.count else { throw WhitegramVoiceProcessingError.tooLong }
            for frame in 0 ..< Int(count) {
                var sum = 0
                for channel in 0 ..< channels { sum += Int(block[frame * channels + channel]) }
                result.append(Int16(clamping: sum / channels))
            }
        }
        guard !result.isEmpty else { throw WhitegramVoiceProcessingError.invalidAudio }
        return result
    }

    static func encode(_ samples: [Int16], task: WhitegramVoiceTask) throws -> WhitegramVoiceProcessedAudio {
        try task.check()
        guard !samples.isEmpty, samples.count <= self.maximumSamples else { throw WhitegramVoiceProcessingError.invalidAudio }
        let data = TGDataItem()
        let writer = TGOggOpusWriter()
        guard writer.begin(with: data) else { throw WhitegramVoiceProcessingError.invalidAudio }
        var frame = [Int16](repeating: 0, count: 960)
        for offset in stride(from: 0, to: samples.count, by: frame.count) {
            try task.check()
            let count = min(frame.count, samples.count - offset)
            for index in 0 ..< count { frame[index] = samples[offset + index] }
            let success = frame.withUnsafeMutableBytes { bytes in
                writer.writeFrame(bytes.baseAddress!.assumingMemoryBound(to: UInt8.self), frameByteCount: UInt(count * 2))
            }
            guard success else { throw WhitegramVoiceProcessingError.invalidAudio }
        }
        guard writer.writeFrame(nil, frameByteCount: 0), let compressed = data.data(), !compressed.isEmpty else { throw WhitegramVoiceProcessingError.invalidAudio }
        var peaks = [Int16](repeating: 0, count: 100)
        for index in samples.indices {
            let bin = min(99, index * 100 / samples.count)
            peaks[bin] = max(peaks[bin], Int16(clamping: abs(Int(samples[index]))))
        }
        let peak = max(2500, Int(Double(peaks.reduce(Int64(0)) { $0 + Int64($1) }) * 1.8 / 100))
        for index in peaks.indices { peaks[index] = Int16(min(31, Int(peaks[index]) * 31 / peak)) }
        let waveform = peaks.withUnsafeBytes { AudioWaveform(samples: Data($0), peak: 31).makeBitstream() }
        return WhitegramVoiceProcessedAudio(data: compressed, duration: writer.encodedDuration(), waveform: waveform)
    }

    static func wav(_ samples: [Int16]) -> Data {
        var data = Data("RIFF".utf8)
        func integer<T: FixedWidthInteger>(_ number: T) {
            var value = number.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        integer(UInt32(36 + samples.count * 2))
        data.append(Data("WAVEfmt ".utf8))
        integer(UInt32(16))
        integer(UInt16(1))
        integer(UInt16(1))
        integer(UInt32(self.sampleRate))
        integer(UInt32(self.sampleRate * 2))
        integer(UInt16(2))
        integer(UInt16(16))
        data.append(Data("data".utf8))
        integer(UInt32(samples.count * 2))
        samples.withUnsafeBytes { data.append(contentsOf: $0) }
        return data
    }
}
