# Whitegram music player

The audio worker supplies native rate/pitch/EQ hooks, two-decoder crossfade, voice auto-next control, bass-driven background darkening and the profile saved-music card. Current integration contract/results: [parity/audio.json](parity/audio.json). This is source-verified work awaiting native audio/UI validation.

## Install map and API

`player_patches.py` exports `PLAYER_RUNTIME_FILES` and `PLAYER_REQUIRED_DEPENDENCIES`.

| `whitegram/cleanroom/` basename | Destination |
| --- | --- |
| `WhitegramPlayerSettings.swift` | `submodules/TelegramCore/Sources/WhitegramPlayerSettings.swift` |
| `WhitegramPlayerFadeEnvelope.swift` | `submodules/TelegramCore/Sources/WhitegramPlayerFadeEnvelope.swift` |
| `WhitegramPlayerBassMeter.swift` | `submodules/TelegramCore/Sources/WhitegramPlayerBassMeter.swift` |
| `WhitegramPlayerAudioUnits.swift` | `submodules/MediaPlayer/Sources/WhitegramPlayerAudioUnits.swift` |
| `WhitegramPlayerAudioSession.swift` | `submodules/TelegramUI/Sources/WhitegramPlayerAudioSession.swift` |
| `WhitegramPlayerCrossfade.swift` | `submodules/TelegramUI/Sources/WhitegramPlayerCrossfade.swift` |
| `WhitegramPlayerBassBackground.swift` | `submodules/TelegramUI/Sources/WhitegramPlayerBassBackground.swift` |
| `WhitegramPlayerProfileCard.swift` | `submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/WhitegramPlayerProfileCard.swift` |
| `WhitegramPlayerSettingsController.swift` | `submodules/SettingsUI/Sources/WhitegramPlayerSettingsController.swift` |

Copy these nine files, then call `apply_player_patches(root) -> dict[str, list[str]]`. `player_patches(patches: SourcePatches)` stages the same transforms inside a parent transaction. Feature reports are `music-native-renderer`, `music-crossfade-and-voice-stop`, `music-bass-driven-background`, and `music-profile-card`.

Transformed sources:

- `submodules/MediaPlayer/Sources/{MediaPlayer,MediaPlayerAudioRenderer}.swift`
- `submodules/TelegramUI/Sources/{SharedMediaPlayer,OverlayAudioPlayerControllerNode}.swift`
- `submodules/TelegramUI/Components/PeerInfo/PeerInfoScreen/Sources/PeerInfoHeaderNode.swift`

SettingsUI entrypoints:

```swift
whitegramPlayerSettingsController(context: AccountContext, equalizerOnly: Bool = false) -> ViewController
whitegramPlayerEqualizerController(context: AccountContext) -> ViewController
```

The controller explicitly imports **PresentationDataUtils**. Required target dependencies already exist in the examined reference: UniversalMediaPlayer → TelegramCore; TelegramUI → UniversalMediaPlayer/TelegramAudio/SwiftSignalKit; SettingsUI → AccountContext/Display/ItemListUI/SwiftSignalKit/TelegramCore/TelegramPresentationData/PresentationDataUtils. The profile decoration uses SDK Foundation/UIKit/QuartzCore in the **PeerInfoScreen** target, not the TelegramUI root target. AudioToolbox/QuartzCore are SDK frameworks. Parent owns installer/menu/generated-state/archive changes.

## Recovered contracts

Original: Whitegram Beta 3.1.1, Telegram 12.9.2 (71), IPA SHA-256 `bd6d3a13046d5857c1389e2d794c4c2ca44cee89bb22880004bd77f84fe29837`.

| Key | Default / runtime policy | Evidence |
| --- | --- | --- |
| `musicPlaybackSpeed` | 1; clamp 0.1...3 | Core/image 46 `0x209aec`, lower constant `0xd55fa8` |
| `musicPlaybackPitchFollowsSpeed` | false | Core `0x209c98` |
| `musicCrossfadeEnabled` | **true** | Core `0x209d94` |
| `musicCrossfadeDuration` | **3** whole seconds; nonnegative | Core `0x209f0c`; UI `0xde79b8` |
| `musicEqualizerEnabled` | false | Core `0x20a084` |
| `musicEqualizerBands` | exactly ten Floats, otherwise ten zeros; −12...12 dB implementation bounds | Core `0x20a180`; UI preset dispatch `0xcb0d30` |
| `stopAfterVoiceMessage` | false; stops voice/round-video auto-next except repeat-one | UI/image 55 `0x4fd004` |
| `bassEffect` | false; background darkening, **not bass boost**; legacy `bassEffectEnabled` alias accepted | Original `s.bassEffect`; UI `0x491dcc` |
| `wgCustomMusicCard` | false; profile saved-track banner; `customMusicCard` alias accepted | Core `0x20c624`; UI `0x7f54a4/0x801bd0` inside profile header |

EQ frequencies: 32, 64, 125, 250, 500, 1000, 2000, 4000, 8000, 16000 Hz. Bass, Treble, Pop, Rock, Jazz and Classical arrays are decoded from original static objects `0x5e47ab8...0x5e47c48` and verified by `tests/voice/recover_original.py`; Neutral is ten zeros. Parent has reconciled music defaults/archive bounds; exact original slider UI limits beyond the evidence remain distinct from the runtime's safe numeric bounds.

## Native pipeline and lifecycle

Only music players receive `isForMusicPlayback`. Both renderer construction paths preserve a public player's current volume, including a zero-volume incoming decoder. Other media retain their original time-pitch unit.

Music uses **converter → NewTimePitch → Varispeed → mixer → ten-band NBandEQ → output**. Fixed-pitch playback sets time-pitch rate to the requested speed, pitch to zero and varispeed to one. Pitch-following splits the rate as `sqrt(speed)` across the two units and applies `1200*log2(sqrt(speed))` cents to NewTimePitch. The product gives the full 0.1...3 rate/pitch while staying inside both units' limits, including speeds below 0.25. Failed graph setup disposes its graph; handles are published only after successful initialization.

Rate, pitch and EQ settings reload on the audio renderer queue, never through preference reads in its render callback. Each EQ band's bypass/gain/frequency is explicitly configured. Music's speed does not alter the voice-message playback-rate preference.

Crossfade schedules from a playing status/timebase in **wall-clock seconds**. It uses the playlist's actual next direction (regular order selects `previousItem`), retains the outgoing decoder, and advances the playlist once. A generation guard ignores the outgoing track's delayed end callback. A shared music-session facade gives both decoders one underlying ManagedAudioSession holder without enabling mixing with other apps.

Incoming gain starts at zero and only fades after a `.playing` status. The envelope is linear, matching the recovered fade direction. Buffering suspends its elapsed time and restores the still-playing outgoing track to full gain. Outgoing end, completion, cancellation or manual controls release the old decoder and restore incoming unity gain. At most one overlap is active. Changing speed reaches both decoders. Pause, seek, manual navigation, disabled crossfade, vanished items, playlist end and teardown cancel timers; an unfulfilled playlist advance has a five-second timeout. Repeat-one, shuffle, unknown next items and tracks no longer than the fade use normal playback.

Bass background uses a bounded 180 Hz stereo energy meter over the renderer's validated **44.1 kHz packed stereo Int16** PCM. Opposite stereo phases do not cancel the meter; samples are never altered. Values reach the background through the existing audio-level signal on the main queue. It respects disabled settings/Reduce Motion and decays when playback stops. Its dimming curve is a functional reconstruction, not a proved original transfer function.

The custom profile card decorates the existing saved-track button with gradient/wave layers and keeps the native track/artist marquee and `displaySavedMusic` action. Original evidence includes the `wgMusicGradientDrift`, `wgMusicWaveDrift`, and `wgMusicWaveDriftSecondary` animation names. The 52-point layout, colors, paths and timing are reconstructed and need screenshot comparison; they are not asserted to be pixel-identical. Disabled mode keeps the native 16/24-point banner. The decoration never intercepts touches and disables motion when requested.

## Verification

```powershell
$env:WHITEGRAM_PLAYER_SOURCE = 'C:\coding\telegram\whitegram\source-12.9.2'
& 'C:\coding\telegram\whitegram\whitegram-check-env\Scripts\python.exe' -B -m unittest discover -s whitegram/tests/player -p 'test_*.py' -v
```

The source suite checks complete install mapping, native dependency paths, both renderer paths, graph-handle lifetime, callback preference isolation, late-anchor atomic failure, PCM-format drift, idempotence, outgoing-player lifetime/generation guards, native card navigation, and Swift syntax including the native test harness. It writes only in-memory copies of the reference.

On a Swift host:

```sh
python3 -B whitegram/tests/player/run_native.py --require-swift
```

Four groups compile the production settings/fade/meter code: original EQ arrays and malformed settings, pitch/rate products and AudioUnit bounds, pause/buffering/restart envelope behavior, and low-frequency/stereo/overflow/reset metering. The native harness has **not executed on Windows**. Full Apple AudioUnit rendering, asynchronous audio-session interruption/routing, rapid seek/skip, streaming stalls, background playback and visual comparison are parent device/build checks.
