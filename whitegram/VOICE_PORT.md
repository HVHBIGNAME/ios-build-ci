# Whitegram voice effects and adapters

Current implementation: local PCM effects, selective Apple Speech bleeping, ElevenLabs conversion, video-note audio replacement, file conversion/export, and outgoing shared-device call PCM. Source checks run against the ready, read-only `C:/coding/telegram/whitegram/source-12.9.2` baseline. Native Swift/codec/device validation remains pending. The machine-readable handoff is [parity/audio.json](parity/audio.json); music is covered in [PLAYER_PORT.md](PLAYER_PORT.md).

## Installation

`voice_patches.py` exports the complete **17-file** `VOICE_RUNTIME_FILES` map. All source basenames below are under `whitegram/cleanroom/`.

| Destination directory | Source basenames |
| --- | --- |
| `submodules/TelegramCore/Sources/` | `WhitegramVoiceSettings.swift`, `WhitegramVoiceDSP.swift`, `WhitegramVoiceBleep.swift`, `WhitegramVoiceProfanityStore.swift`, `WhitegramVoiceCredentials.swift`, `WhitegramVoiceRemote.swift`, `WhitegramVoiceHTTP.swift`, `WhitegramVoiceAudioFile.swift`, `WhitegramVoiceSpeech.swift`, `WhitegramVoicePostprocessor.swift`, `WhitegramVoiceVideo.swift` |
| `submodules/TelegramUI/Sources/` | `WhitegramVoiceChat.swift` |
| `submodules/TelegramVoip/Sources/` | `WhitegramVoiceCallProcessor.swift` |
| `submodules/SettingsUI/Sources/` | `WhitegramVoiceSliderItem.swift`, `WhitegramVoiceSettingsController.swift`, `WhitegramVoiceRemoteSettingsController.swift`, `WhitegramVoiceFileController.swift` |

Copy the files, then invoke `apply_voice_patches(root) -> dict[str, list[str]]`. For a larger atomic transaction, call `voice_patches(patches: SourcePatches)` and let the parent write once. `apply_voice_pcm_patches(root)` remains the narrow, backwards-compatible recorder-only API used by the baseline regressions.

The full transform stages these features before writing:

1. `voice-message-local-pcm`: recorder construction, complete-packet processing, resume reset.
2. `voice-selective-bleep-and-remote-send`: Opus channel-count accessor; immediate audio send and draft send.
3. `voice-outgoing-call-pcm`: Swift shared audio device and both Objective-C++ outgoing transport overloads.
4. `voice-video-note-audio`: video-note processing, cancellation and live-upload eligibility.

SettingsUI entrypoints:

```swift
whitegramVoiceSettingsController(context: AccountContext) -> ViewController
whitegramVoiceRemoteSettingsController(context: AccountContext) -> ViewController
WhitegramVoiceFileController(context: AccountContext)
```

The first screen connects the other two. Key entry is secure; available voices are fetched only on the user's connection-check action. Selecting a voice saves its ID and display name together. Connection status is the result of that request, not a persisted success flag.

### Dependencies and parent integration

- TelegramCore needs `//submodules/OpusBinding:OpusBinding` and `//submodules/AudioWaveform:AudioWaveform`. SDK imports include AVFoundation, Speech and Security. The pure settings/DSP/matcher remain Foundation/CoreFoundation code.
- TelegramUI's adapter explicitly imports AccountContext, **ChatInterfaceState**, ChatPresentationInterfaceState, AudioWaveform, Display, SwiftSignalKit, TelegramCore and **PresentationDataUtils**.
- SettingsUI uses its existing AccountContext/Display/ItemListUI/SwiftSignalKit/TelegramCore/TelegramPresentationData/PresentationDataUtils/AsyncDisplayKit dependencies. The file controller uses UIKit.
- TelegramVoip needs TelegramCore, already present in the reference. The native hook uses the existing TgVoipWebrtc target.
- `VideoMessageCameraScreen` already depends on TelegramCore and PresentationDataUtils; no reverse dependency on TelegramUI is introduced.
- **Add/verify `NSSpeechRecognitionUsageDescription` in the application plist.** The runtime refuses to request authorization when it is missing. The original microphone permission is still used for recording.
- Parent owns generic preference/archive/generated-state integration. Reconcile generated `voiceChangerUseProxy` to **true**, and include `voiceChangerVoiceId`/`voiceChangerVoiceName` as strings. The absent-value proxy default is proved at Core `0x20b954`.
- Keychain item: generic password, service `Whitegram.Voice.ElevenLabs`, account `api-key`, accessibility `AfterFirstUnlockThisDeviceOnly`. The runtime migrates a canonical legacy `voiceChangerApiKey` value and clears it only after saving the Keychain item. Parent archive integration must include this item if credential transfer is enabled. Importing original raw `wg_*` settings into canonical preferences remains a parent migration responsibility.

#### Backend hooks

```swift
WhitegramVoiceRuntime.configureProxyRequest(requestBuilder, session: pinnedSession)
WhitegramVoiceProfanityStore.shared.configure(loader: profanityLoader)
```

`requestBuilder` receives `(path, method, optionalProviderKey, accept)` and must create the original authenticated/signed Whitegram request for provider **`elevenlabs`**. The supplied URLSession must enforce the parent's pinning, redirect, response-transfer bounds and account/session policy. Both builder and session are required for actual proxy traffic. Missing integration returns `proxyUnavailable`; it never silently sends directly. Direct traffic uses a serial delegate with a 64 MiB incremental body limit and rejects redirects.

`profanityLoader` takes a completion `(Result<Data, Error>) -> Void`, fetches signed **`GET /v1/config/profanity`**, and returns a `WhitegramVoiceTask` whose cancellation cancels that request. Response fields are `roots: [String]` and optional `prefixes: [String]`. The store validates before replacing the original `wg_profanityRoots_v2`, `wg_profanityPrefixes_v2`, and `wg_profanityRootsUpdatedAt_v2` cache. The recovered freshness interval is **86400 seconds** and the speech pipeline waits at most **4 seconds** for refresh; cached or original bundled roots remain available on failure.

## Original evidence

Evidence root: `C:/coding/telegram/whitegram/whitegram-rebuild`. Current focused exports: `C:/coding/telegram/whitegram/recovery_20261002/campaign/audio/`. Original IPA SHA-256:

`bd6d3a13046d5857c1389e2d794c4c2ca44cee89bb22880004bd77f84fe29837`

- Core/image 46: preset IDs `0...10` at `0x2d6264/0x2d626c`; configuration gate `0x2d7a6c`; parameter dispatch `0x2d672c`; constant tables `0xd68800...0xd68a50`.
- Core processing: pitch `0x2d6d48`, warm-up/order/limiter `0x2d69f0`, tone `0x2d7044`, modulation/noise/distortion `0x2d7388`, echo `0x2d75e8`.
- Core profanity matching `0x27f4e8`, refresh `0x27fd08`, response/cache `0x280258`. Bounds for timbre/clarity are recovered through `0x212884/0x213060`: −100...100, nonfinite to zero.
- UI/image 55: bleep word intervals `0x5a423c`; tone/silence renderer `0x5a44e0`; Apple Speech adapter `0x5a4994`; remote multipart request `0xdc821c`; `changeVoice` `0xdc9f38`; `changeVideoAudio` `0xdcbca0`.

`tests/voice/recover_original.py` verifies the IPA hash and decodes the actual jump-table/constant-pool preset values. `original_audio_fixture.json` is the verified native-test fixture. This is evidence for coefficients and protocol, not an assertion that Apple codecs or output samples have already been compared on device.

## Settings and processing contracts

| Key | Default / behavior |
| --- | --- |
| `voiceChangerEnabled` | false; local DSP also requires local mode and a known preset |
| `voiceChangerMode` | 0 = ElevenLabs; 1 = local; unknown values inactive |
| `voiceChangerPreset` | 0 = Custom; then Echo, Child, Adult, Robot, Helium, Monster, Radio, Whisper, Alien, Cavern |
| `voiceChangerPitch` | 0; −12...12 semitones; half-semitone UI steps |
| `voiceChangerTimbre`, `voiceChangerClarity` | 0; −100...100 percent |
| `voiceChangerEcho` | 0; 0...100 percent |
| `voiceBleepEnabled`, `voiceBleepMode` | false; 0 = beep, 1 = silence; selective word censoring unless whole-recording opt-in is set |
| `voiceBleepWholeRecording` | existing port-only default-false opt-in; never inferred from the original selective-bleep flag |
| `voiceChangerVoiceId`, `voiceChangerVoiceName` | empty strings until selected |
| `voiceChangerApiKey` | migrated to the Keychain item above; empty direct key is an error |
| `voiceChangerUseProxy` | **true when absent**; explicit false selects direct ElevenLabs |
| `voiceChangerInCalls` | false; local effects only on the shared outgoing audio device |

Recovered local preset controls, in pitch/timbre/echo/clarity order:

| Preset | Controls | Other operations |
| --- | --- | --- |
| Echo | 0 / 0 / 72 / 12 | — |
| Child | 6.2 / 56 / 4 / 35 | — |
| Adult | −3.8 / −34 / 3 / −8 | — |
| Robot | −0.7 / 24 / 10 / 36 | 74 Hz ring; 0.34 distortion |
| Helium | 9 / 72 / 2 / 44 | — |
| Monster | −8 / −76 / 18 / −32 | 0.27 distortion |
| Radio | 0 / 78 / 2 / 70 | 0.18 distortion |
| Whisper | 0 / 62 / 3 / 40 | 0.82 envelope-shaped noise mix |
| Alien | 4.8 / 38 / 28 / 20 | 31 Hz ring; 0.12 distortion |
| Cavern | −1.3 / −25 / 90 / −20 | — |

### Local recording and calls

The recorder still processes only its owned **960-sample, 48 kHz, mono Int16** packet before waveform generation and the existing Opus writer. The apparent `16000 / 1000 * 60 * 2` expression is 1920 bytes at 48 kHz, not a 16 kHz input. Partial-buffer ownership and timing are preserved; reset runs before resume/trim.

DSP order is pitch → 55 ms startup blend → timbre/clarity → ring/noise/distortion → echo → soft-knee limiting. Pitch uses the recovered 90 ms history, triangular two-head weights and 16...84% read bounds (75.6 ms maximum delay at 48 kHz). Echo delay is `0.16 + amount * 0.22` seconds, with feedback `0.18 + amount * 0.48`. No effect tails or padding are added by local DSP. Neutral, disabled and unknown selections preserve PCM bit-for-bit.

The mono API supports 8...192 kHz. Interleaved/planar Int16 and Float adapters preserve independent channel state. The call adapter preallocates mono/stereo processors for 8/16/32/44.1/48/96 kHz, snapshots changes outside the callback, and processes a bounded owned native copy. The existing device mutex plus the processor lock serialize reconfiguration. Bleep and remote conversion are excluded from live calls. Device deactivation resets the histories.

### Send-time processing

- Pause/preview retains the original resumable Ogg. Local effects are already audible there; remote conversion and selective bleeping run on send, after trimming.
- Immediate-send and draft-send postprocessors are cancellable. Failure retains the recording/draft and presents an error. Changed/deleted/trimmed drafts reject stale results. The draft send hook runs after slow-mode eligibility and forwards scheduling, silent posting, repeat period, view-once, effect and postpone arguments.
- Voice/privacy composition is tested in **both orders**, including replay. Audio changes only the function parameter list; privacy independently inserts its record-once eligibility check. The processed-audio retry still passes through that eligibility check.
- Bleep uses Apple Speech word timestamps, original roots/prefixes, `ё → е`, and letter-containing `*` masks. It retains the first 30% and last 35% of each matching word, at least 10 ms per edge. Missing/very short durations use 300 ms. Overlapping intervals are merged. Beep is 1 kHz, 9000 Int16 peak, with 5 ms ramps; silence is exact zero. Whole-recording masking retains its separate 0.16-peak tone behavior.
- Direct conversion: `POST https://api.elevenlabs.io/v1/speech-to-speech/{voiceId}?output_format=mp3_44100_128`, `xi-api-key`, `Accept: audio/mpeg`; multipart `model_id=eleven_multilingual_sts_v2`, `file_format=other`, `audio=voice.wav`. Voice list: `GET /v1/voices`. HTTP/decoding failures are errors, not successful empty results. Direct sessions are ephemeral and reject redirects.
- Video notes snapshot settings at camera-screen creation and disable live upload when audio processing is requested. They concatenate/trim recorded segments, process audio, encode AAC, and remux with passthrough video. Failure restores send eligibility and the preview. Original view-once/schedule behavior composes with the audio hook and camera transform.
- File conversion uses coordinated/security-scoped import and uniquely owned staging. Audio exports Ogg; video exports MP4. Cancellation/generation checks reject stale callbacks and staging survives until its last asynchronous user finishes.

## Checks and remaining validation

```powershell
$env:WHITEGRAM_VOICE_SOURCE = 'C:\coding\telegram\whitegram\source-12.9.2'
& 'C:\coding\telegram\whitegram\whitegram-check-env\Scripts\python.exe' -B -m unittest discover -s whitegram/tests/voice -p 'test_*.py' -v
& 'C:\coding\telegram\whitegram\whitegram-rebuild\.venv\Scripts\python.exe' -B whitegram/tests/voice/recover_original.py 'C:\coding\telegram\whitegram\whitegram-rebuild' --verify-fixture whitegram/tests/voice/original_audio_fixture.json
```

The source suite checks all runtime files, Swift syntax, real ItemList/BUILD contracts, complete adapter replay, fail-before-write, packet-format drift, both privacy orders and both camera orders. It never writes the reference. See `parity/audio.json` for the final measured results.

On the parent's macOS/Swift host:

```sh
python3 -B whitegram/tests/voice/run_native.py --require-swift
python3 -B whitegram/tests/voice/run_native.py --require-swift --sanitize-address
```

The harness compiles production code: **15 DSP groups** (including original preset coefficients and stereo/Float adapters), plus **4 protocol/matcher/cache groups** using a local URLProtocol fixture. No live provider requests are made by these tests.

**No Swift executable, iOS typecheck, codec round-trip, Speech run, live call, or device audio check ran on Windows.** Required remaining checks: native harness; full Xcode build/Objective-C bridging; Opus partial-final-frame duration/waveform; Speech authorization/locale/cancellation; video trim/AAC remux and A/V timing; call route/mute/interruption behavior; and recorded output against the original IPA.

Known limits: processing is bounded to 20 minutes and file input/output to 256 MiB; remote responses to 64 MiB. Video segments with incompatible transforms are rejected. Converted audio is clipped/padded to the original picture duration rather than retiming the picture; remote-service duration drift needs lip-sync validation. The legacy non-shared call-device path, exact voice-picker preview UX, original full visual layout, and complete localization of explanatory text are not claimed as restored. Proxy authentication/pinning and signed profanity refresh require the parent hooks above.
