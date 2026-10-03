import Foundation
import AVFoundation

public struct WhitegramVoiceProcessedVideo {
    public let data: Data
    public let duration: Double
}

public enum WhitegramVoiceVideo {
    @discardableResult
    public static func process(urls: [URL], settings: WhitegramVoiceSettings, locale: String, trimRange: Range<Double>? = nil, completion: @escaping (Result<WhitegramVoiceProcessedVideo, WhitegramVoiceProcessingError>) -> Void) -> WhitegramVoiceTask {
        let task = WhitegramVoiceTask()
        let service = WhitegramVoiceRuntime.remoteService()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try task.check()
                let directory = try WhitegramVoiceTemporaryDirectory()
                let composition = try self.composition(urls: urls, task: task)
                let duration = CMTimeGetSeconds(composition.duration)
                let range = trimRange ?? (0 ..< duration)
                guard range.lowerBound.isFinite, range.upperBound.isFinite,
                      range.lowerBound >= 0, range.upperBound > range.lowerBound, range.upperBound <= duration + 0.05 else { throw WhitegramVoiceProcessingError.invalidAudio }
                let start = CMTime(seconds: range.lowerBound, preferredTimescale: 48000)
                let end = CMTime(seconds: min(duration, range.upperBound), preferredTimescale: 48000)
                let selected = CMTimeRange(start: start, end: end)
                let trimmed = AVMutableComposition()
                guard let sourceVideo = composition.tracks(withMediaType: .video).first,
                      let sourceAudio = composition.tracks(withMediaType: .audio).first,
                      let videoTrack = trimmed.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
                      let audioTrack = trimmed.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw WhitegramVoiceProcessingError.invalidAudio }
                try videoTrack.insertTimeRange(selected, of: sourceVideo, at: .zero)
                videoTrack.preferredTransform = sourceVideo.preferredTransform
                let selectedAudio = CMTimeRangeGetIntersection(selected, otherRange: sourceAudio.timeRange)
                guard selectedAudio.duration > .zero else { throw WhitegramVoiceProcessingError.invalidAudio }
                try audioTrack.insertTimeRange(selectedAudio, of: sourceAudio, at: selectedAudio.start - selected.start)
                let samples = try WhitegramVoiceAudioFile.decode(asset: trimmed, task: task)
                try WhitegramVoicePostprocessor.transform(samples: samples, directory: directory, settings: settings, locale: locale, applyLocalEffects: true, service: service, task: task) { result in
                    do {
                        try task.check()
                        let samples = try result.get()
                        let wav = try directory.write(WhitegramVoiceAudioFile.wav(samples), name: "processed.wav")
                        let audio = directory.url.appendingPathComponent("processed.m4a")
                        self.export(AVURLAsset(url: wav), to: audio, preset: AVAssetExportPresetAppleM4A, type: .m4a, task: task) { result in
                            do {
                                try result.get()
                                try self.replaceAudio(in: trimmed, with: AVURLAsset(url: audio))
                                let output = directory.url.appendingPathComponent("video.mp4")
                                self.export(trimmed, to: output, preset: AVAssetExportPresetPassthrough, type: .mp4, task: task) { result in
                                    do {
                                        try result.get()
                                        try task.check()
                                        let data = try self.read(output, maximumBytes: 256 * 1024 * 1024, task: task)
                                        WhitegramVoicePostprocessor.deliver(.success(WhitegramVoiceProcessedVideo(data: data, duration: CMTimeGetSeconds(selected.duration))), task: task, completion: completion)
                                    } catch { WhitegramVoicePostprocessor.deliver(.failure(WhitegramVoicePostprocessor.error(error)), task: task, completion: completion) }
                                    withExtendedLifetime(directory) {}
                                }
                            } catch { WhitegramVoicePostprocessor.deliver(.failure(WhitegramVoicePostprocessor.error(error)), task: task, completion: completion) }
                        }
                    } catch { WhitegramVoicePostprocessor.deliver(.failure(WhitegramVoicePostprocessor.error(error)), task: task, completion: completion) }
                }
            } catch { WhitegramVoicePostprocessor.deliver(.failure(WhitegramVoicePostprocessor.error(error)), task: task, completion: completion) }
        }
        return task
    }

    private static func composition(urls: [URL], task: WhitegramVoiceTask) throws -> AVMutableComposition {
        guard !urls.isEmpty, urls.count <= 128 else { throw WhitegramVoiceProcessingError.invalidAudio }
        let result = AVMutableComposition()
        guard let video = result.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let audio = result.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw WhitegramVoiceProcessingError.invalidAudio }
        var position = CMTime.zero
        for url in urls {
            try task.check()
            let asset = AVURLAsset(url: url)
            let seconds = CMTimeGetSeconds(asset.duration)
            guard seconds.isFinite, seconds > 0 else { throw WhitegramVoiceProcessingError.invalidAudio }
            guard CMTimeGetSeconds(position) + seconds <= 1200 else { throw WhitegramVoiceProcessingError.tooLong }
            guard let source = asset.tracks(withMediaType: .video).first else { throw WhitegramVoiceProcessingError.invalidAudio }
            if position == .zero { video.preferredTransform = source.preferredTransform }
            guard source.preferredTransform == video.preferredTransform else { throw WhitegramVoiceProcessingError.invalidAudio }
            let range = CMTimeRange(start: .zero, duration: asset.duration)
            try video.insertTimeRange(range, of: source, at: position)
            if let source = asset.tracks(withMediaType: .audio).first {
                let available = CMTimeRangeGetIntersection(range, otherRange: source.timeRange)
                if available.duration > .zero { try audio.insertTimeRange(available, of: source, at: position + available.start) }
            }
            position = position + asset.duration
        }
        guard !audio.segments.isEmpty else { throw WhitegramVoiceProcessingError.invalidAudio }
        return result
    }

    private static func replaceAudio(in video: AVMutableComposition, with audio: AVAsset) throws {
        let duration = video.duration
        for track in video.tracks(withMediaType: .audio) { video.removeTrack(track) }
        guard let source = audio.tracks(withMediaType: .audio).first,
              let destination = video.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw WhitegramVoiceProcessingError.invalidAudio }
        let range = CMTimeRange(start: .zero, duration: CMTimeMinimum(duration, audio.duration))
        try destination.insertTimeRange(range, of: source, at: .zero)
        // Keep the video timeline: service output may have small encoder padding
        // or different speech duration. Never truncate or retime the picture.
        if range.duration < duration {
            destination.insertEmptyTimeRange(CMTimeRange(start: range.duration, duration: duration - range.duration))
        }
    }

    private static func export(_ asset: AVAsset, to url: URL, preset: String, type: AVFileType, task: WhitegramVoiceTask, completion: @escaping (Result<Void, WhitegramVoiceProcessingError>) -> Void) {
        guard !task.isCancelled else { return }
        guard let export = AVAssetExportSession(asset: asset, presetName: preset), export.supportedFileTypes.contains(type) else { completion(.failure(.invalidAudio)); return }
        export.outputURL = url
        export.outputFileType = type
        task.onCancel { export.cancelExport() }
        export.exportAsynchronously {
            DispatchQueue.global(qos: .userInitiated).async {
                guard !task.isCancelled else { return }
                if export.status == .completed {
                    completion(.success(Void()))
                } else {
                    completion(.failure(.conversion(export.error ?? WhitegramVoiceProcessingError.invalidAudio)))
                }
            }
        }
    }

    public static func read(_ url: URL, maximumBytes: Int, task: WhitegramVoiceTask) throws -> Data {
        guard maximumBytes > 0, let stream = InputStream(url: url) else { throw WhitegramVoiceProcessingError.invalidAudio }
        stream.open()
        defer { stream.close() }
        var result = Data()
        var block = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            try task.check()
            let count = block.withUnsafeMutableBufferPointer { stream.read($0.baseAddress!, maxLength: $0.count) }
            guard count >= 0 else { throw WhitegramVoiceProcessingError.invalidAudio }
            if count == 0 { break }
            guard count <= maximumBytes - result.count else { throw WhitegramVoiceProcessingError.tooLong }
            result.append(contentsOf: block.prefix(count))
        }
        guard !result.isEmpty else { throw WhitegramVoiceProcessingError.invalidAudio }
        return result
    }
}
