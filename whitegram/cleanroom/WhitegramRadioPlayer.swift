import Foundation
import AVFoundation
import MediaPlayer
import UIKit
import AccountContext
import TelegramAudio
import SwiftSignalKit
import TelegramCore

final class WhitegramRadioPlayer: NSObject, AVPlayerItemMetadataOutputPushDelegate {
    enum State: Equatable { case stopped, waiting, playing, paused, failed(String) }
    static let shared = WhitegramRadioPlayer()
    static let updated = Notification.Name("WhitegramRadioPlayerUpdated")
    private(set) var station: WhitegramRadioStation?
    private(set) var track: WhitegramRadioTrack?
    private(set) var state: State = .stopped
    private(set) var metadataError: String?
    private(set) var serviceError: String?
    private(set) var listenerError: String?
    private(set) var presenceError: String?
    private(set) var listeners: Int?
    private var player: AVPlayer?
    private var playerObservation: NSKeyValueObservation?
    private var itemObservation: NSKeyValueObservation?
    private var metadataOutput: AVPlayerItemMetadataOutput?
    private var audioSessionDisposable: Disposable?
    private var heartbeat: Foundation.Timer?
    private var listening: WhitegramRadioHeartbeatPublisher?
    private var listenerTask: WhitegramBackendTask?
    private var client: WhitegramBackendClient?
    private var context: AccountContext?
    private var generation = 0
    private var metadataSession: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var remoteTargets: [(MPRemoteCommand, Any)] = []
    private var interruptionObserver: NSObjectProtocol?
    private var settingsObserver: NSObjectProtocol?
    private var presence: WhitegramProfilePresencePublisher?
    private var listenerRevision = 0

    private override init() {
        super.init()
        interruptionObserver = NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] notification in
            if let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
               AVAudioSession.RouteChangeReason(rawValue: raw) == .oldDeviceUnavailable { self?.pause() }
        }
        settingsObserver = whitegramServiceObserve(WhitegramPreferences.updatedNotification) { [weak self] _ in self?.updatePresence() }
    }

    func play(_ station: WhitegramRadioStation, context: AccountContext, client: WhitegramBackendClient) {
        precondition(Thread.isMainThread)
        stop()
        self.context = context
        self.client = client
        self.station = station
        self.state = .waiting
        if listening?.userId != client.userId {
            listening = WhitegramRadioHeartbeatPublisher(client: client) { [weak self] error in
                guard let self, self.client?.userId == client.userId else { return }
                serviceError = error?.localizedDescription
                notify()
            }
        }
        if presence?.userId != client.userId {
            presence = WhitegramProfilePresencePublisher(client: client) { [weak self] error in
                guard let self, presence?.userId == client.userId else { return }
                presenceError = error?.localizedDescription
                notify()
            }
        }
        let generation = self.generation
        let item = AVPlayerItem(url: station.streamURL)
        let output = AVPlayerItemMetadataOutput(identifiers: nil)
        output.setDelegate(self, queue: .main)
        item.add(output)
        metadataOutput = output
        let player = AVPlayer(playerItem: item)
        self.player = player
        itemObservation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self, generation == self.generation else { return }
                if item.status == .failed {
                    stopPlayback()
                    state = .failed("The station could not be played (\((item.error as NSError?)?.code ?? 0)).")
                    notify()
                }
            }
        }
        playerObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] player, _ in
            DispatchQueue.main.async {
                guard let self, generation == self.generation else { return }
                switch player.timeControlStatus {
                case .playing: state = .playing
                case .waitingToPlayAtSpecifiedRate: if state != .paused { state = .waiting }
                case .paused: if state == .playing { state = .paused }
                @unknown default: break
                }
                updatePresence()
                reportListening()
                notify()
            }
        }
        acquireAudio(generation: generation)
        startMetadata(station: station, generation: generation)
        installRemoteCommands()
        heartbeat = Foundation.Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.reportListening(); self?.updatePresence() }
        refreshListeners()
        notify()
    }

    private func acquireAudio(generation: Int) {
        guard let context else { return }
        audioSessionDisposable = context.sharedContext.mediaManager.audioSession.push(audioSessionType: .play(mixWithOthers: false), activate: { [weak self] _ in
            DispatchQueue.main.async {
                guard let self, generation == self.generation, state != .paused else { return }
                player?.play()
            }
        }, deactivate: { [weak self] _ in
            return Signal { subscriber in
                DispatchQueue.main.async {
                    if let self, generation == self.generation { self.pause() }
                    subscriber.putCompletion()
                }
                return EmptyDisposable
            }
        })
    }

    func pause() {
        precondition(Thread.isMainThread)
        guard player != nil else { return }
        player?.pause()
        state = .paused
        audioSessionDisposable?.dispose()
        audioSessionDisposable = nil
        reportListening()
        updatePresence()
        notify()
    }

    func resume() {
        precondition(Thread.isMainThread)
        guard player != nil, state == .paused else { return }
        state = .waiting
        if audioSessionDisposable == nil { acquireAudio(generation: generation) }
        else { player?.play() }
        notify()
    }

    func stop() {
        precondition(Thread.isMainThread)
        generation += 1
        stopPlayback()
        station = nil
        track = nil
        state = .stopped
        context = nil
        client = nil
        listeners = nil
        metadataError = nil
        serviceError = nil
        listenerError = nil
        notify()
    }

    private func stopPlayback() {
        presence?.update(nil)
        listening?.update(playing: false)
        player?.pause()
        playerObservation = nil
        itemObservation = nil
        metadataOutput = nil
        player?.replaceCurrentItem(with: nil)
        player = nil
        audioSessionDisposable?.dispose()
        audioSessionDisposable = nil
        heartbeat?.invalidate()
        heartbeat = nil
        listenerTask?.cancel()
        listenerRevision += 1
        listenerTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        metadataSession?.invalidateAndCancel()
        metadataSession = nil
        for (command, target) in remoteTargets { command.removeTarget(target) }
        remoteTargets.removeAll()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private func updatePresence() {
        guard state == .playing, WhitegramPreferences.bool("whitegramPresenceEnabled"), let station else {
            presence?.update(nil)
            return
        }
        presence?.update(.radio(station: station, track: track, precise: WhitegramPreferences.bool("whitegramPresencePreciseEnabled")))
    }

    private func notify() {
        if let station {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: track?.title ?? station.name,
                MPMediaItemPropertyArtist: track?.artist ?? station.name, MPNowPlayingInfoPropertyIsLiveStream: true,
                MPNowPlayingInfoPropertyPlaybackRate: state == .playing ? 1.0 : 0.0]
        }
        NotificationCenter.default.post(name: Self.updated, object: self)
    }

    private func installRemoteCommands() {
        let center = MPRemoteCommandCenter.shared()
        for (command, action) in [(center.playCommand, 0), (center.pauseCommand, 1), (center.stopCommand, 2), (center.togglePlayPauseCommand, 3)] {
            let target = command.addTarget { [weak self] _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    switch action {
                    case 0: resume()
                    case 1: pause()
                    case 2: stop()
                    default: if state == .playing { pause() } else { resume() }
                    }
                }
                return .success
            }
            remoteTargets.append((command, target))
        }
    }

    private func reportListening() {
        guard client != nil else { return }
        listening?.update(playing: state == .playing)
    }

    func refreshListeners() {
        guard let client else { return }
        listenerTask?.cancel()
        listenerRevision += 1
        let revision = listenerRevision
        let generation = self.generation
        listenerTask = client.request(WhitegramRadioListeners.self, path: "/v1/radio/listeners") { [weak self] result in
            guard let self, generation == self.generation, revision == listenerRevision else { return }
            listenerTask = nil
            switch result {
            case let .success(result): listeners = result.count >= 0 ? result.count : nil; listenerError = result.count >= 0 ? nil : WhitegramBackendError.invalidResponse.localizedDescription
            case let .failure(error): listeners = nil; listenerError = error.localizedDescription
            }
            notify()
        }
    }

    private func startMetadata(station: WhitegramRadioStation, generation: Int) {
        guard let channel = station.emgChannel else { return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil
        let session = URLSession(configuration: configuration)
        metadataSession = session
        let socket = session.webSocketTask(with: WhitegramRadioMetadata.socketURL)
        self.socket = socket
        socket.maximumMessageSize = 256 * 1024
        socket.resume()
        do {
            let data = try WhitegramRadioMetadata.subscription(channel: channel)
            socket.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] error in
                DispatchQueue.main.async {
                    guard let self, generation == self.generation else { return }
                    if let error { metadataError = "Radio metadata connection failed (\((error as NSError).code))."; notify() }
                    else { receiveMetadata(channel: channel, generation: generation) }
                }
            }
        } catch { metadataError = "Could not subscribe to radio metadata."; notify() }
    }

    private func receiveMetadata(channel: String, generation: Int) {
        socket?.receive { [weak self] result in
            DispatchQueue.main.async {
                guard let self, generation == self.generation else { return }
                switch result {
                case let .failure(error): metadataError = "Radio metadata connection failed (\((error as NSError).code))."; notify()
                case let .success(message):
                    let data: Data
                    switch message {
                    case let .data(value): data = value
                    case let .string(value): data = Data(value.utf8)
                    @unknown default: metadataError = "Unsupported radio metadata message."; notify(); return
                    }
                    do {
                        if let track = try WhitegramRadioMetadata.emg(data, channel: channel) { self.track = track; metadataError = nil; updatePresence(); notify() }
                    } catch { metadataError = "Radio metadata was not a valid track update."; notify() }
                    receiveMetadata(channel: channel, generation: generation)
                }
            }
        }
    }

    func metadataOutput(_ output: AVPlayerItemMetadataOutput, didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup], from track: AVPlayerItemTrack?) {
        guard output === metadataOutput, let station, station.emgChannel == nil, player != nil else { return }
        for item in groups.flatMap({ $0.items }) {
            if let value = item.stringValue, let track = WhitegramRadioMetadata.icy(value) { self.track = track; metadataError = nil; updatePresence(); notify() }
        }
    }
}
