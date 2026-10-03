"""Native music-player hooks for Telegram 12.9.2; copying/menu wiring is parent-owned."""

from pathlib import Path

from source_patches import SourcePatches


PLAYER_RUNTIME_FILES = {
    "WhitegramPlayerSettings.swift": "submodules/TelegramCore/Sources/WhitegramPlayerSettings.swift",
    "WhitegramPlayerFadeEnvelope.swift": "submodules/TelegramCore/Sources/WhitegramPlayerFadeEnvelope.swift",
    "WhitegramPlayerBassMeter.swift": "submodules/TelegramCore/Sources/WhitegramPlayerBassMeter.swift",
    "WhitegramPlayerBassBackground.swift": "submodules/TelegramUI/Sources/WhitegramPlayerBassBackground.swift",
    "WhitegramPlayerProfileCard.swift": "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/WhitegramPlayerProfileCard.swift",
    "WhitegramPlayerAudioUnits.swift": "submodules/MediaPlayer/Sources/WhitegramPlayerAudioUnits.swift",
    "WhitegramPlayerAudioSession.swift": "submodules/TelegramUI/Sources/WhitegramPlayerAudioSession.swift",
    "WhitegramPlayerCrossfade.swift": "submodules/TelegramUI/Sources/WhitegramPlayerCrossfade.swift",
    "WhitegramPlayerSettingsController.swift": "submodules/SettingsUI/Sources/WhitegramPlayerSettingsController.swift",
}

PLAYER_REQUIRED_DEPENDENCIES = {
    "MediaPlayer": ["//submodules/TelegramCore:TelegramCore", "//submodules/Postbox:Postbox"],
    "TelegramUI": ["//submodules/MediaPlayer:UniversalMediaPlayer", "//submodules/TelegramAudio:TelegramAudio"],
    "SettingsUI": ["//submodules/PresentationDataUtils:PresentationDataUtils"],
}

PLAYER = "submodules/MediaPlayer/Sources/MediaPlayer.swift"
RENDERER = "submodules/MediaPlayer/Sources/MediaPlayerAudioRenderer.swift"
SHARED = "submodules/TelegramUI/Sources/SharedMediaPlayer.swift"
OVERLAY = "submodules/TelegramUI/Sources/OverlayAudioPlayerControllerNode.swift"
PROFILE = "submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoHeaderNode.swift"

SHARED_PROPERTIES = """    private let whitegramMusicSession: WhitegramPlayerAudioSession?
    private let whitegramCrossfade = WhitegramPlayerCrossfade()
    private var whitegramCrossfadeTimer: SwiftSignalKit.Timer?
    private var whitegramMusicObserver: NSObjectProtocol?
    private var whitegramOutgoing: MediaPlayer?
    private var whitegramAdvanceRequested = false
    private var whitegramPlaybackGeneration = 0
    private var whitegramAdvanceTimeout: SwiftSignalKit.Timer?

"""

SHARED_METHODS = """    private func whitegramCancelCrossfade() {
        self.whitegramCrossfadeTimer?.invalidate()
        self.whitegramCrossfadeTimer = nil
        self.whitegramAdvanceTimeout?.invalidate()
        self.whitegramAdvanceTimeout = nil
        self.whitegramCrossfade.cancel()
        self.whitegramOutgoing?.pause()
        self.whitegramOutgoing = nil
        self.whitegramAdvanceRequested = false
    }

    private func whitegramScheduleCrossfade() {
        self.whitegramCrossfadeTimer?.invalidate()
        self.whitegramCrossfadeTimer = nil
        guard self.type == .music, !self.whitegramAdvanceRequested, !self.whitegramCrossfade.isActive,
              let state = self.stateValue, state.looping != .item, state.order != .random,
              let next = (state.order == .regular ? state.previousItem : state.nextItem),
              next.playbackData?.type == .music,
              next.playbackData != state.item?.playbackData,
              case let .audio(player) = self.playbackItem,
              case let .item(item) = self._playbackStateValue,
              case .playing = item.status.status else { return }
        let settings = WhitegramPlayerSettings(values: WhitegramPreferences.values())
        let elapsed = item.status.generationTimestamp > 0 ? max(0, CACurrentMediaTime() - item.status.generationTimestamp) : 0
        let timestamp = item.status.timestamp + elapsed * item.status.baseRate
        guard let delay = settings.crossfadeDelay(duration: item.status.duration, timestamp: timestamp, rate: item.status.baseRate) else { return }
        let timer = SwiftSignalKit.Timer(timeout: max(0.01, delay), repeat: false, completion: { [weak self, weak player] in
            guard let self, let player, case let .audio(current) = self.playbackItem, current === player else { return }
            self.whitegramAdvanceRequested = true
            self.whitegramOutgoing = player
            self.scheduledPlaybackAction = .play
            let timeout = SwiftSignalKit.Timer(timeout: 5, repeat: false, completion: { [weak self] in
                guard let self, self.whitegramAdvanceRequested else { return }
                self.whitegramCancelCrossfade()
                self.scheduledPlaybackAction = nil
            }, queue: .mainQueue())
            self.whitegramAdvanceTimeout = timeout
            timeout.start()
            self.playlist.control(.next)
        }, queue: .mainQueue())
        self.whitegramCrossfadeTimer = timer
        timer.start()
    }

    private func whitegramBeginCrossfade() {
        self.whitegramAdvanceTimeout?.invalidate()
        self.whitegramAdvanceTimeout = nil
        guard let outgoing = self.whitegramOutgoing, case let .audio(incoming) = self.playbackItem else {
            self.whitegramCancelCrossfade()
            return
        }
        self.whitegramOutgoing = nil
        let duration = WhitegramPlayerSettings(values: WhitegramPreferences.values()).crossfadeDuration
        self.whitegramCrossfade.start(outgoing: outgoing, incoming: incoming, duration: duration, completion: { [weak self] in
            self?.whitegramScheduleCrossfade()
        })
    }

    private func whitegramReloadMusicSettings() {
        guard self.type == .music else { return }
        let settings = WhitegramPlayerSettings(values: WhitegramPreferences.values())
        if case let .audio(player) = self.playbackItem { player.setBaseRate(settings.speed) }
        self.whitegramOutgoing?.setBaseRate(settings.speed)
        self.whitegramCrossfade.setBaseRate(settings.speed)
        if !settings.crossfadeEnabled { self.whitegramCancelCrossfade() }
        self.whitegramScheduleCrossfade()
    }

"""


def _patch_player(patches: SourcePatches) -> None:
    feature = "music-native-renderer"
    patches.replace(feature, PLAYER, "    private let isAudioVideoMessage: Bool\n", "    private let isAudioVideoMessage: Bool\n    private let isForMusicPlayback: Bool\n    private var whitegramVolume: Double = 1.0\n")
    patches.replace(feature, PLAYER, "isAudioVideoMessage: Bool) {", "isAudioVideoMessage: Bool, isForMusicPlayback: Bool) {")
    patches.replace(feature, PLAYER, "isAudioVideoMessage: Bool = false) {", "isAudioVideoMessage: Bool = false, isForMusicPlayback: Bool = false) {")
    patches.replace(feature, PLAYER, "        self.isAudioVideoMessage = isAudioVideoMessage\n", "        self.isAudioVideoMessage = isAudioVideoMessage\n        self.isForMusicPlayback = isForMusicPlayback\n")
    patches.replace(feature, PLAYER, "storeAfterDownload: storeAfterDownload, isAudioVideoMessage: isAudioVideoMessage)", "storeAfterDownload: storeAfterDownload, isAudioVideoMessage: isAudioVideoMessage, isForMusicPlayback: isForMusicPlayback)")
    patches.replace(feature, PLAYER, "forAudioVideoMessage: self.isAudioVideoMessage, playAndRecord:", "forAudioVideoMessage: self.isAudioVideoMessage, isForMusicPlayback: self.isForMusicPlayback, playAndRecord:", count=2)
    patches.replace(feature, PLAYER, "self.audioRenderer = MediaPlayerAudioRendererContext(renderer: renderer)\n", "self.audioRenderer = MediaPlayerAudioRendererContext(renderer: renderer)\n                renderer.setVolume(self.whitegramVolume)\n", count=2)
    patches.replace(feature, PLAYER, "    fileprivate func setBaseRate(_ baseRate: Double) {\n", """    fileprivate func whitegramSetVolume(_ volume: Double) {
        guard volume.isFinite else { return }
        self.whitegramVolume = min(1, max(0, volume))
        self.audioRenderer?.renderer.setVolume(self.whitegramVolume)
    }

    fileprivate func setBaseRate(_ baseRate: Double) {
""")
    patches.replace(feature, PLAYER, "    public func setBaseRate(_ baseRate: Double) {\n", """    public func setVolume(_ volume: Double) {
        self.queue.async {
            if let context = self.contextRef?.takeUnretainedValue() {
                context.whitegramSetVolume(volume)
            }
        }
    }

    public func setBaseRate(_ baseRate: Double) {
""")


def _patch_renderer(patches: SourcePatches) -> None:
    feature = "music-native-renderer"
    patches.replace(feature, RENDERER, """            guard NewAUGraph(&maybeAudioGraph) == noErr, let audioGraph = maybeAudioGraph else {
                return
            }
""", """            guard NewAUGraph(&maybeAudioGraph) == noErr, let audioGraph = maybeAudioGraph else {
                return
            }
            var whitegramGraphInstalled = false
            defer {
                if !whitegramGraphInstalled { DisposeAUGraph(audioGraph) }
            }
""")
    patches.replace(feature, RENDERER, "    let forAudioVideoMessage: Bool\n", "    let forAudioVideoMessage: Bool\n    let isForMusicPlayback: Bool\n    var whitegramSettingsObserver: NSObjectProtocol?\n")
    patches.replace(feature, RENDERER, "    var timePitchAudioUnit: AudioComponentInstance?\n", "    var timePitchAudioUnit: AudioComponentInstance?\n    var whitegramVarispeedAudioUnit: AudioComponentInstance?\n")
    patches.replace(feature, RENDERER, "forAudioVideoMessage: Bool, playAndRecord:", "forAudioVideoMessage: Bool, isForMusicPlayback: Bool, playAndRecord:")
    patches.replace(feature, RENDERER, "forAudioVideoMessage: Bool = false, playAndRecord:", "forAudioVideoMessage: Bool = false, isForMusicPlayback: Bool = false, playAndRecord:")
    patches.replace(feature, RENDERER, "forAudioVideoMessage: forAudioVideoMessage, playAndRecord:", "forAudioVideoMessage: forAudioVideoMessage, isForMusicPlayback: isForMusicPlayback, playAndRecord:")
    patches.replace(feature, RENDERER, "        self.forAudioVideoMessage = forAudioVideoMessage\n", "        self.forAudioVideoMessage = forAudioVideoMessage\n        self.isForMusicPlayback = isForMusicPlayback\n")
    patches.replace(feature, RENDERER, "        self.bufferContextId = registerPlayerRendererBufferContext(self.bufferContext)\n", """        self.bufferContextId = registerPlayerRendererBufferContext(self.bufferContext)
        if self.isForMusicPlayback {
            self.whitegramSettingsObserver = NotificationCenter.default.addObserver(forName: WhitegramPreferences.updatedNotification, object: nil, queue: nil, using: { [weak self] _ in
                audioPlayerRendererQueue.async { [weak self] in self?.whitegramReloadSettings() }
            })
        }
""")
    patches.replace(feature, RENDERER, "        unregisterPlayerRendererBufferContext(self.bufferContextId)\n", "        if let observer = self.whitegramSettingsObserver { NotificationCenter.default.removeObserver(observer) }\n        unregisterPlayerRendererBufferContext(self.bufferContextId)\n")
    patches.replace(feature, RENDERER, "            timePitchDescription.componentSubType = kAudioUnitSubType_AUiPodTimeOther\n", "            timePitchDescription.componentSubType = self.isForMusicPlayback ? kAudioUnitSubType_NewTimePitch : kAudioUnitSubType_AUiPodTimeOther\n")
    patches.replace(feature, RENDERER, "            var mixerNode: AUNode = 0\n", """            var whitegramVarispeedNode: AUNode = 0
            var whitegramVarispeedDescription = AudioComponentDescription(componentType: kAudioUnitType_FormatConverter, componentSubType: kAudioUnitSubType_Varispeed, componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
            if self.isForMusicPlayback {
                guard AUGraphAddNode(audioGraph, &whitegramVarispeedDescription, &whitegramVarispeedNode) == noErr else { return }
            }
            var mixerNode: AUNode = 0
""")
    patches.replace(feature, RENDERER, """            guard AUGraphConnectNodeInput(audioGraph, timePitchNode, 0, mixerNode, 0) == noErr else {
                return
            }
""", """            if self.isForMusicPlayback {
                guard AUGraphConnectNodeInput(audioGraph, timePitchNode, 0, whitegramVarispeedNode, 0) == noErr,
                      AUGraphConnectNodeInput(audioGraph, whitegramVarispeedNode, 0, mixerNode, 0) == noErr else { return }
            } else {
                guard AUGraphConnectNodeInput(audioGraph, timePitchNode, 0, mixerNode, 0) == noErr else { return }
            }
""")
    patches.replace(feature, RENDERER, "            AudioUnitSetParameter(timePitchAudioUnit, kTimePitchParam_Rate, kAudioUnitScope_Global, 0, Float32(self.baseRate), 0)\n", """            var whitegramVarispeed: AudioComponentInstance?
            if self.isForMusicPlayback {
                guard AUGraphNodeInfo(audioGraph, whitegramVarispeedNode, &whitegramVarispeedDescription, &whitegramVarispeed) == noErr, let whitegramVarispeed else { return }
                WhitegramPlayerAudioUnits.configurePitch(timePitchAudioUnit, varispeed: whitegramVarispeed, settings: WhitegramPlayerSettings(values: WhitegramPreferences.values()), rate: self.baseRate)
            } else {
                AudioUnitSetParameter(timePitchAudioUnit, kTimePitchParam_Rate, kAudioUnitScope_Global, 0, Float32(self.baseRate), 0)
            }
""")
    patches.replace(feature, RENDERER, """        if let timePitchAudioUnit = self.timePitchAudioUnit, !self.baseRate.isEqual(to: baseRate) {
            self.baseRate = baseRate
            AudioUnitSetParameter(timePitchAudioUnit, kTimePitchParam_Rate, kAudioUnitScope_Global, 0, Float32(baseRate), 0)
""", """        if !self.baseRate.isEqual(to: baseRate) {
            self.baseRate = baseRate
            if let timePitchAudioUnit = self.timePitchAudioUnit {
                if self.isForMusicPlayback, let varispeed = self.whitegramVarispeedAudioUnit {
                    WhitegramPlayerAudioUnits.configurePitch(timePitchAudioUnit, varispeed: varispeed, settings: WhitegramPlayerSettings(values: WhitegramPreferences.values()), rate: baseRate)
                } else {
                    AudioUnitSetParameter(timePitchAudioUnit, kTimePitchParam_Rate, kAudioUnitScope_Global, 0, Float32(baseRate), 0)
                }
            }
""")
    patches.replace(feature, RENDERER, "            if self.forAudioVideoMessage && !self.ambient {\n", """            if self.isForMusicPlayback {
                WhitegramPlayerAudioUnits.configureEqualizer(equalizerAudioUnit, settings: WhitegramPlayerSettings(values: WhitegramPreferences.values()), initialize: true)
            }
            if self.forAudioVideoMessage && !self.ambient {
""")
    patches.replace(feature, RENDERER, "    fileprivate func setVolume(_ volume: Double) {\n", """    private func whitegramReloadSettings() {
        let settings = WhitegramPlayerSettings(values: WhitegramPreferences.values())
        if let unit = self.timePitchAudioUnit, let varispeed = self.whitegramVarispeedAudioUnit {
            WhitegramPlayerAudioUnits.configurePitch(unit, varispeed: varispeed, settings: settings, rate: self.baseRate)
        }
        if let unit = self.equalizerAudioUnit {
            WhitegramPlayerAudioUnits.configureEqualizer(unit, settings: settings, initialize: false)
        }
    }

    fileprivate func setVolume(_ volume: Double) {
""")
    patches.replace(feature, RENDERER, "            var maximumFramesPerSlice: UInt32 = 4096\n", """            var maximumFramesPerSlice: UInt32 = 4096
            if let varispeed = whitegramVarispeed {
                AudioUnitSetProperty(varispeed, kAudioUnitProperty_MaximumFramesPerSlice, kAudioUnitScope_Global, 0, &maximumFramesPerSlice, 4)
            }
""")
    patches.replace(feature, RENDERER, "            self.audioGraph = audioGraph\n", "            whitegramGraphInstalled = true\n            self.audioGraph = audioGraph\n            self.whitegramVarispeedAudioUnit = whitegramVarispeed\n")
    patches.replace(feature, RENDERER, "            self.timePitchAudioUnit = nil\n", "            self.timePitchAudioUnit = nil\n            self.whitegramVarispeedAudioUnit = nil\n")


def _patch_bass(patches: SourcePatches) -> None:
    feature = "music-bass-driven-background"
    for anchor in ("    canonicalBasicStreamDescription.mSampleRate = 44100.00\n", "    canonicalBasicStreamDescription.mChannelsPerFrame = 2\n", "    canonicalBasicStreamDescription.mBitsPerChannel = 8 * 2\n", "    canonicalBasicStreamDescription.mBytesPerFrame = 2 * 2\n", "    canonicalBasicStreamDescription.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagsNativeEndian | kAudioFormatFlagIsPacked\n"):
        if patches.read(RENDERER).count(anchor) != 1:
            raise ValueError(f"{feature}: unexpected renderer PCM format: {anchor!r}")
    patches.replace(feature, RENDERER, "    var audioLevelPeak: Int16 = 0\n", "    var audioLevelPeak: Int16 = 0\n    var whitegramBassMeter: WhitegramPlayerBassMeter?\n")
    patches.replace(feature, RENDERER, "        self.bufferContextId = registerPlayerRendererBufferContext(self.bufferContext)\n", """        if self.isForMusicPlayback {
            self.bufferContext.with { $0.whitegramBassMeter = WhitegramPlayerBassMeter() }
        }
        self.bufferContextId = registerPlayerRendererBufferContext(self.bufferContext)
""")
    patches.replace(feature, RENDERER, "                                    var sample: Int16 = samplePtr.pointee\n", "                                    context.whitegramBassMeter?.append(left: samplePtr.pointee, right: samplePtr.advanced(by: 1).pointee)\n                                    var sample: Int16 = samplePtr.pointee\n")
    patches.replace(feature, RENDERER, "                                        let level = Float(context.audioLevelPeak) / (4000.0)\n", "                                        let level = context.whitegramBassMeter?.level ?? (Float(context.audioLevelPeak) / 4000.0)\n")
    patches.replace(feature, RENDERER, "            context.bufferMaxChannelSampleIndex = 0\n", "            context.bufferMaxChannelSampleIndex = 0\n            context.whitegramBassMeter?.reset()\n            context.audioLevelPeak = 0\n            context.audioLevelPeakCount = 0\n")
    patches.replace(feature, SHARED, """                    self.audioLevelDisposable.set((player.audioLevelEvents.startStrict(next: { [weak audioLevelPipe] value in
                        audioLevelPipe?.putNext(value)
""", """                    self.audioLevelDisposable.set((player.audioLevelEvents |> deliverOnMainQueue).startStrict(next: { [weak self, weak audioLevelPipe] value in
                        audioLevelPipe?.putNext(value)
                        if let self, self.type == .music, let context = self.context {
                            WhitegramPlayerBassEvents.levels.putNext((context.account.id.int64, value))
                        }
""")
    patches.replace(feature, SHARED, """                        audioLevelPipe?.putNext(value)
                        if let self, self.type == .music, let context = self.context {
                            WhitegramPlayerBassEvents.levels.putNext((context.account.id.int64, value))
                        }
                    })))
""", """                        audioLevelPipe?.putNext(value)
                        if let self, self.type == .music, let context = self.context {
                            WhitegramPlayerBassEvents.levels.putNext((context.account.id.int64, value))
                        }
                    }))
""")
    patches.replace(feature, OVERLAY, "    private let dimNode: ASDisplayNode\n", "    private let dimNode: ASDisplayNode\n    private let whitegramBassBackground: WhitegramPlayerBassBackground\n")
    patches.replace(feature, OVERLAY, "        self.dimNode = ASDisplayNode()\n", "        self.whitegramBassBackground = WhitegramPlayerBassBackground(accountId: context.account.id.int64)\n        self.dimNode = ASDisplayNode()\n")
    patches.replace(feature, OVERLAY, "        self.addSubnode(self.dimNode)\n", "        self.addSubnode(self.dimNode)\n        if self.type == .music { self.dimNode.view.addSubview(self.whitegramBassBackground) }\n")
    patches.replace(feature, OVERLAY, "        transition.updateFrame(node: self.dimNode, frame: CGRect(origin: CGPoint(), size: layout.size))\n", "        transition.updateFrame(node: self.dimNode, frame: CGRect(origin: CGPoint(), size: layout.size))\n        self.whitegramBassBackground.frame = CGRect(origin: .zero, size: layout.size)\n")


def _patch_shared(patches: SourcePatches) -> None:
    feature = "music-crossfade-and-voice-stop"
    patches.replace(feature, SHARED, "import UIKit\n", "import UIKit\nimport QuartzCore\n")
    patches.replace(feature, SHARED, "    private var playbackRate: AudioPlaybackRate\n", SHARED_PROPERTIES + "    private var playbackRate: AudioPlaybackRate\n")
    patches.replace(feature, SHARED, "        self.audioSession = audioSession\n", "        self.audioSession = audioSession\n        self.whitegramMusicSession = type == .music ? WhitegramPlayerAudioSession(base: audioSession) : nil\n")
    patches.replace(feature, SHARED, "        playlist.currentItemDisappeared = { [weak self] in\n", """        self.whitegramMusicObserver = NotificationCenter.default.addObserver(forName: WhitegramPreferences.updatedNotification, object: nil, queue: .main, using: { [weak self] _ in
            self?.whitegramReloadMusicSettings()
        })

        playlist.currentItemDisappeared = { [weak self] in
            self?.whitegramCancelCrossfade()
""")
    patches.replace(feature, SHARED, """                if state.item?.playbackData != strongSelf.stateValue?.item?.playbackData {
                    if let playbackItem = strongSelf.playbackItem {
                        switch playbackItem {
                            case .audio:
                                playbackItem.pause()
""", """                if state.item?.playbackData != strongSelf.stateValue?.item?.playbackData {
                    strongSelf.whitegramPlaybackGeneration += 1
                    if !strongSelf.whitegramAdvanceRequested { strongSelf.whitegramCrossfade.cancel() }
                    strongSelf.whitegramCrossfadeTimer?.invalidate()
                    strongSelf.whitegramCrossfadeTimer = nil
                    if let playbackItem = strongSelf.playbackItem {
                        switch playbackItem {
                            case let .audio(player):
                                if player !== strongSelf.whitegramOutgoing { playbackItem.pause() }
""")
    patches.replace(feature, SHARED, "                            rateValue = 1.0\n", "                            rateValue = WhitegramPlayerSettings(values: WhitegramPreferences.values()).speed\n")
    patches.replace(feature, SHARED, "MediaPlayer(audioSessionManager: strongSelf.audioSession, postbox:", "MediaPlayer(audioSessionManager: strongSelf.whitegramMusicSession ?? strongSelf.audioSession, postbox:")
    patches.replace(feature, SHARED, "isAudioVideoMessage: playbackData.type == .voice))", "isAudioVideoMessage: playbackData.type == .voice, isForMusicPlayback: playbackData.type == .music))")
    patches.replace(feature, SHARED, """                        playbackItem.setForceAudioToSpeaker(strongSelf.forceAudioToSpeaker)
                        playbackItem.setActionAtEnd({
""", """                        playbackItem.setForceAudioToSpeaker(strongSelf.forceAudioToSpeaker)
                        strongSelf.whitegramBeginCrossfade()
                        strongSelf.whitegramAdvanceRequested = false
                        let whitegramGeneration = strongSelf.whitegramPlaybackGeneration
                        playbackItem.setActionAtEnd({
""")
    patches.replace(feature, SHARED, """                                if let strongSelf = self {
                                    switch strongSelf.playlist.looping {
""", """                                if let strongSelf = self, strongSelf.whitegramPlaybackGeneration == whitegramGeneration, !strongSelf.whitegramAdvanceRequested {
                                    switch strongSelf.playlist.looping {
""")
    patches.replace(feature, SHARED, """                                        default:
                                            strongSelf.scheduledPlaybackAction = .play
                                            strongSelf.control(.next)
""", """                                        default:
                                            if strongSelf.type == .voice && WhitegramPlayerSettings(values: WhitegramPreferences.values()).stopAfterVoiceMessage {
                                                strongSelf.playbackItem?.pause()
                                                strongSelf.mediaManager?.setPlaylist(nil, type: .voice, control: .playback(.pause))
                                            } else {
                                                strongSelf.scheduledPlaybackAction = .play
                                                strongSelf.control(.next)
                                            }
""")
    patches.replace(feature, SHARED, "            self?._playbackStateValue = value\n", "            self?._playbackStateValue = value\n            self?.whitegramScheduleCrossfade()\n")
    patches.replace(feature, SHARED, "                    if state.playedToEnd {\n", "                    if state.playedToEnd {\n                        strongSelf.whitegramCancelCrossfade()\n")
    patches.replace(feature, SHARED, "                    let rateValue: Double = baseRate.doubleValue\n", "                    let rateValue: Double = self.type == .music ? WhitegramPlayerSettings(values: WhitegramPreferences.values()).speed : baseRate.doubleValue\n")
    patches.replace(feature, SHARED, "    deinit {\n        self.stateDisposable?.dispose()\n", "    deinit {\n        self.whitegramCancelCrossfade()\n        if let observer = self.whitegramMusicObserver { NotificationCenter.default.removeObserver(observer) }\n        self.stateDisposable?.dispose()\n")
    patches.replace(feature, SHARED, "    func control(_ action: SharedMediaPlayerControlAction) {\n        switch action {\n", """    func control(_ action: SharedMediaPlayerControlAction) {
        self.whitegramCancelCrossfade()
        switch action {
""")
    patches.replace(feature, SHARED, "    func stop() {\n", "    func stop() {\n        self.whitegramCancelCrossfade()\n")
    patches.replace(feature, SHARED, "    private func updatePrefetchItems(item:", SHARED_METHODS + "    private func updatePrefetchItems(item:")


def _patch_profile_card(patches: SourcePatches) -> None:
    feature = "music-profile-card"
    patches.replace(feature, PROFILE, "    var musicBackground: UIView?\n", "    var musicBackground: UIView?\n    private var whitegramMusicCard: WhitegramPlayerProfileCard?\n")
    patches.replace(feature, PROFILE, "        let musicHeight: CGFloat = hasBackground || self.isAvatarExpanded ? 24.0 : 16.0\n", """        let whitegramCustomMusicCard = WhitegramPlayerSettings(values: WhitegramPreferences.values()).customMusicCard
        let musicHeight: CGFloat = whitegramCustomMusicCard ? 52.0 : (hasBackground || self.isAvatarExpanded ? 24.0 : 16.0)
""")
    patches.replace(feature, PROFILE, """                if additive {
                    musicTransition.updateFrameAdditiveToCenter(view: musicView, frame: musicFrame)
""", """                if whitegramCustomMusicCard {
                    let card = self.whitegramMusicCard ?? WhitegramPlayerProfileCard(frame: .zero)
                    self.whitegramMusicCard = card
                    if card.superview !== musicView { musicView.insertSubview(card, at: 0) }
                    card.frame = CGRect(origin: .zero, size: musicFrame.size).insetBy(dx: 12, dy: 4)
                    card.update(accent: isOverlay ? .white : presentationData.theme.list.itemAccentColor, overlay: isOverlay)
                } else {
                    self.whitegramMusicCard?.removeFromSuperview()
                    self.whitegramMusicCard = nil
                }
                if additive {
                    musicTransition.updateFrameAdditiveToCenter(view: musicView, frame: musicFrame)
""")
    patches.replace(feature, PROFILE, """            if let music = self.music {
                self.music = nil
""", """            self.whitegramMusicCard?.removeFromSuperview()
            self.whitegramMusicCard = nil
            if let music = self.music {
                self.music = nil
""")


def player_patches(patches: SourcePatches) -> None:
    _patch_player(patches)
    _patch_renderer(patches)
    _patch_shared(patches)
    _patch_bass(patches)
    _patch_profile_card(patches)


def apply_player_patches(root: Path) -> dict[str, list[str]]:
    patches = SourcePatches(root)
    player_patches(patches)
    return patches.write()
