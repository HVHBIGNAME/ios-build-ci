# Whitegram local voice effects

Runtime copying, recorder patching and main-menu routing are connected. The macOS workflow now invokes the native harness; its execution remains pending. See [PORT_STATUS.md](PORT_STATUS.md).

## Integration handoff

The implementation processes the microphone's **48 kHz, mono, signed Int16 PCM before Telegram's existing Ogg Opus encoder**. It includes duration-preserving pitch, tone controls, all eleven recovered preset selections, and explicitly opted-in whole-message beep/silence replacement. The UI entrypoint is:

```swift
public func whitegramVoiceSettingsController(context: AccountContext) -> ViewController
```

It belongs to **SettingsUI**. Opening the screen reads settings only; listening uses Telegram's normal recording preview. The parent should route the `voiceChanger` menu entry to this function.

Copy these files from `whitegram/cleanroom/` before building:

| File | Destination |
| --- | --- |
| `WhitegramVoiceSettings.swift` | `submodules/TelegramCore/Sources/WhitegramVoiceSettings.swift` |
| `WhitegramVoiceDSP.swift` | `submodules/TelegramCore/Sources/WhitegramVoiceDSP.swift` |
| `WhitegramVoiceSliderItem.swift` | `submodules/SettingsUI/Sources/WhitegramVoiceSliderItem.swift` |
| `WhitegramVoiceSettingsController.swift` | `submodules/SettingsUI/Sources/WhitegramVoiceSettingsController.swift` |

The same mapping is exported as `VOICE_RUNTIME_FILES` by `whitegram/voice_patches.py`. Parent integration calls `apply_voice_patches(root: Path) -> dict[str, list[str]]` after runtime copying. It uses the parent's `SourcePatches.replace(..., count=1)` and `write()`, with all anchors validated before writes. Its report key is `voice-message-local-pcm`.

### Dependencies

- **TelegramCore runtime:** Foundation and CoreFoundation only. `WhitegramVoiceSettings(values:)` accepts a primitive dictionary; DSP does not import TelegramUIPreferences, Display, UIKit, AVFoundation, Accelerate, or a network client.
- **SettingsUI:** AccountContext, Display, ItemListUI, SwiftSignalKit, TelegramCore, TelegramPresentationData; the slider also uses UIKit and AsyncDisplayKit. All module dependencies already exist in the examined `SettingsUI/BUILD`. Its recursive Swift source glob includes the new files.
- **TelegramUI hook:** existing `import TelegramCore` and existing Bazel dependency suffice. The Core classes/methods used across the boundary are public.
- **Preferences:** the screen uses the parent's `WhitegramPreferences.values()`, `update(_:) -> Bool`, and `updatedNotification`. It reports save failures and refreshes external changes. The recorder takes a single dictionary snapshot at context construction. Primitive mirroring to `wg_<key>` is handled by the parent preferences implementation.
- **Frameworks/build:** Foundation/CoreFoundation/UIKit are SDK frameworks. No extra third-party library, audio engine, framework declaration, build target, microphone permission, or plist entry is introduced by these files.

## Source paths examined

Authoritative source: `C:\Users\Pisun4ik\AppData\Local\Temp\opencode\whitegram-port-12.9.2`.
Additional compatibility target: `C:\Users\Pisun4ik\AppData\Local\Temp\wg`.

1. `submodules/TelegramUI/Sources/ManagedAudioRecorder.swift`
   - `rendererInputProc` allocates the incoming AudioBuffer and schedules `processAndDisposeAudioBuffer` on the recorder's serial `Queue`.
   - `audioRecorderNativeStreamDescription` specifies one channel and packed signed 16-bit samples. `setupAudioUnit()` explicitly requests **48000 Hz**.
   - `processAndDisposeAudioBuffer` copies PCM into an owned encoder packet and retains incomplete input in `audioBuffer`. Only the complete-packet branch is hooked.
2. `submodules/OpusBinding/Sources/opusenc/opusenc.m` and its public `TGOggOpusWriter.h`
   - The writer initializes `rate = 48000`, `coding_rate = 48000`, `frame_size = 960` and calls `opus_encode` with signed Int16 PCM.
   - The recorder's misleading `16000 / 1000 * 60 * 2` arithmetic also produces **1920 bytes = 960 samples = 20 ms at 48 kHz**. It is not a 16 kHz DSP input.
   - `encodedDuration` comes from `total_samples / coding_rate`; the new code never changes these values or frame sizes.
3. `submodules/TelegramUI/Sources/Chat/ChatControllerMediaRecording.swift`
   - `requestAudioRecorder` obtains the managed recorder via `mediaManager.audioRecorder`.
   - Both preview/pause and immediate-send paths store `data.compressedData` from `takenRecordedData()`.
   - Preview-send uses the same resource (or the existing trim path). Messages retain `audio/ogg`, `.Audio(isVoice: true, ...)`, existing duration, and the generated waveform.

Consequently the processed samples feed **waveform, recording preview, draft resource, immediate send, and preview send** through the existing encoder/resource path. This is not a playback-rate effect or a second send-time transcoder.

## Recovered settings and behavior

Evidence inspected under `C:\coding\telegram\whitegram\whitegram-rebuild\recovered-3.1.1\native`, with menu evidence in the sibling `whitegram-rebuild\menu-cases-3.1.1` directory:

- `TelegramCoreFramework-0/types.json`: `WGVoiceEffectPreset` has `custom, echo, child, adult, robot, helium, monster, radio, whisper, alien, cavern` in that order. Its raw-value accessor at `0x2d6264` returns the case byte; the initializer at `0x2d626c` accepts `0..<11`.
- `TelegramCoreFramework-0/assembly/002d7a6c-bb707db036.asm`: `SGSettings.voiceChangerConfiguration` enables local processing only when `voiceChangerEnabled` is true and `voiceChangerMode == 1`.
- `0020bd34-bf4eb24635.asm` explicitly bounds pitch to **−12…+12**. `0020c0a8-a99db092c6.asm` bounds echo to **0…100**. Timbre/clarity getters call a shared clamp helper, and the active-configuration predicate treats both as signed controls. This port uses documented **−100…+100** ranges; the shared helper's numeric limits were not independently recovered.
- `TelegramUIFramework-0/symbols.json` exposes `WGVoiceBleepProcessor.transcribeAndBleep(samples:sampleRate:appLocale:completion:)` and `process(oggPath:appLocale:completion:)`. This is evidence of word/transcription-based postprocessing, not a constant tone added to microphone audio.
- `menu-cases-3.1.1/menu-cases.json` identifies the ElevenLabs mode label and beep/silence selector labels. The two bleep selector labels appear in beep-then-silence order; `0 = beep, 1 = silence` is the port's corresponding selector mapping.

Preset names, selection IDs, key names and the local-mode gate match this evidence. **Filter coefficients, preset sounds, pitch algorithm, and signed-percentage UI are functional reimplementations**, not claims of identical IPA audio output or visuals.

| Key | Local implementation |
| --- | --- |
| `voiceChangerEnabled` | Gates local effects together with `voiceChangerMode == 1`. The local switch explicitly selects mode 1 when enabled. |
| `voiceChangerMode` | `0`: remote/ElevenLabs, unavailable; `1`: on-device. Unknown values are inactive rather than silently converted to a working mode. |
| `voiceChangerPreset` | IDs `0…10` listed below. Unknown IDs are inactive. Presets use fixed coefficients; Custom uses the four stored controls. |
| `voiceChangerPitch` | −12…+12 semitones, UI step 0.5; actual fractional-delay pitch processing at fixed sample rate/count. |
| `voiceChangerTimbre` | −100…+100%, UI step 1; negative values darken and positive values brighten a 900 Hz low/high split. This is tone EQ, not independent vocal-formant shifting. |
| `voiceChangerEcho` | 0…100%, UI step 1; 180 ms feedback delay for Custom, bounded feedback up to 0.5. |
| `voiceChangerClarity` | −100…+100%, UI step 1; negative smooths around 1.6 kHz, positive reduces rumble around 100 Hz and increases presence above 2.5 kHz. No speech denoiser is claimed. |
| `voiceBleepEnabled` / `voiceBleepMode` | Whole-message replacement is available only with the new explicit opt-in below. Otherwise a recovered automatic-word-bleep request is inactive and explained in the UI. |
| `voiceBleepWholeRecording` | Additional default-false port marker. The clearly labeled “Replace Entire Voice Message” switch writes this with `voiceBleepEnabled`. `0 = beep` produces a 1 kHz tone at 0.16 peak with a 5 ms initial attack; `1 = silence` writes exact zero. It replaces all audio, including pauses, and takes precedence over local presets. |
| `voiceChangerInCalls` | Read for status only. The call control always displays **off and unavailable**, even if the saved request is true. |

Controls reject booleans/strings as numbers; NaN/infinities become neutral; finite out-of-range values are clamped. Enum decoding requires an exactly representable integer. Opening settings does not rewrite invalid/imported values. Failed preference saves do not optimistically enable an effect.

### Local presets

| ID | Name | Implemented operations |
| --- | --- | --- |
| 0 | Custom | Stored pitch/timbre/echo/clarity; all-zero Custom is bit-identical bypass |
| 1 | Echo | 55% echo, 180 ms delay |
| 2 | Child | +5 st, brighter timbre and presence |
| 3 | Adult | −3 st, warmer timbre |
| 4 | Robot | 65 Hz ring modulation, mix 0.85, tone/presence shaping |
| 5 | Helium | +9 st, brighter timbre/presence |
| 6 | Monster | −8 st, dark timbre, 32 Hz modulation and echo |
| 7 | Radio | Approximately 300–3400 Hz shaping and soft saturation |
| 8 | Whisper | Noise shaped by the voice envelope, mixed with 10% voice; a breathy effect, not linguistic resynthesis |
| 9 | Alien | +4 st, 110 Hz modulation, bright timbre and echo |
| 10 | Cavern | −1 st, smoothing, 80% echo with 300 ms delay |

## PCM operations and lifetime

The patch inserts three operations into `ManagedAudioRecorderContext`:

1. Construct one `WhitegramVoiceProcessor` using `WhitegramPreferences.values()` and 48000 Hz beside the recorder's packet buffer property.
2. Borrow the **complete, already-owned** packet through `UnsafeMutableBufferPointer<Int16>` and process it immediately before `processWaveformPreview` and `oggWriter.writeFrame`.
3. Reset DSP state at the beginning of `resume()`, before trimming/restarting. This prevents an echo or delayed pitch sample from replaying a removed segment.

Local effect order: normalized PCM → pitch (if nonzero) → timbre/clarity → preset radio shaping → ring modulation/noise envelope where selected → echo → rounded, saturating Int16. Explicit whole-message masking short-circuits this chain and reads no microphone samples.

- DSP is confined to the existing serial recorder queue, **not the AudioUnit render callback**. Processing does not read preferences, allocate buffers, acquire locks, change sessions, perform I/O, or retain incoming pointers.
- The caller's existing `malloc`, packet copies, partial-packet staging and both `defer/free` blocks retain ownership. The processor writes only within the borrowed count and never calls `free`.
- Delay buffers are instance-owned and allocated at construction. At 48 kHz, the largest preset uses about 128 KiB of sample history. Ring indices/phases stay bounded over long recordings.
- Disabled, neutral and unknown/remote local-effect selections bypass PCM before any floating-point conversion, unless explicitly opted-in bleep is active independently. Invalid sample rates bypass both effects and bleep.
- Echo/pitch/filter/noise state survives arbitrary packet boundaries. Pause/resume deliberately starts a fresh effect segment. A persisted draft reopened as a **new recorder** takes current settings for newly appended audio; previously encoded audio is not transformed again. An existing recorder retains its original configuration snapshot.
- No effect tails or synthetic padding packets are appended. The existing treatment of a final incomplete recorder packet is retained. Effects preserve the number of samples passed to the encoder.
- Pitch is a complementary-Hann two-head fractional-delay effect, with ratio `2^(semitones/12)` and a 40 ms moving window. It has a variable delay of at most **40 ms + 2 samples** (about 40.042 ms at 48 kHz), startup history filling, possible grain/modulation artifacts, and a truncated delayed tail at stop/reset. Upward shifts use a two-stage input low-pass to reduce high-frequency aliasing; this is not a studio-quality, formant-preserving or perfect anti-aliasing pitch processor.
- API accepts mono rates from 8–192 kHz with finite validation; the actual recorder hook is guarded to **48 kHz**. No stereo/planar/call adapter is supplied.

## Validation

From the parent repository root, Python checks use in-memory file objects around the **real** `SourcePatches`; neither examined source checkout is patched on disk:

```powershell
$env:WHITEGRAM_VOICE_SOURCE = 'C:\Users\Pisun4ik\AppData\Local\Temp\opencode\whitegram-port-12.9.2'
$env:WHITEGRAM_VOICE_PUBLIC_SOURCE = 'C:\Users\Pisun4ik\AppData\Local\Temp\wg'
& 'C:\Users\Pisun4ik\AppData\Local\Temp\opencode\whitegram-check-env\Scripts\python.exe' -B -m unittest discover -s whitegram/tests/voice -p 'test_*.py' -v
```

**Observed: 13 Python tests pass** against both roots. Checks cover packet-hook ordering, resume placement, atomic anchor rejection, rate/channel/sample-width/encoder drift, unchanged source bytes, idempotence, CRLF handling, existing Bazel dependencies, and actual ItemList API signatures. Tree-sitter **0.25.2 + tree-sitter-swift 0.7.3** parses all four runtime files, the native harness, and patched full recorder source. Parsing is not Swift typechecking.

The native harness compiles **the production settings and DSP files**, without a Python DSP clone or UIKit/Telegram stubs:

```sh
python3 -B whitegram/tests/voice/run_native.py --require-swift
# On a Swift toolchain with AddressSanitizer:
python3 -B whitegram/tests/voice/run_native.py --require-swift --sanitize-address
```

It uses `swiftc -parse-as-library -O -warnings-as-errors` and writes build output only under `whitegram/tests/voice/.native/`. Thirteen native groups check exhaustive Int16 disabled identity, finite/bounded controls, borrowed-buffer boundaries and lifetime, sample-count and packet-partition invariance, echo delay/decay/persistence, reset equivalence, full-scale saturation without wraparound, audible presets/silent input, pitch-frequency movement at unchanged duration, tone spectral balance, independent simultaneous processors, bleep opt-in/tone/masking/reset, and invalid rates/immutable snapshots. Frequency tests use a Goertzel analyzer of the real output.

**Observed native result: SKIP — `swiftc` is unavailable on this host. No native DSP assertions, iOS typecheck, Opus round-trip, acoustic-quality test, or device performance measurement has run here.** `--require-swift` turns a missing compiler into a CI failure rather than a pass. Parent validation still needs the native harness and an actual Telegram build/device recording-preview-send test, including pause/trim/resume and a restored draft.

## Unsupported / exact remaining limits

- Automatic word/profanity detection and selective word bleeping from the recovered transcription pipeline are **not implemented**. Whole-message replacement is deliberately a separate opt-in with explicit semantics; it is not presented as automatic censoring.
- Remote ElevenLabs/API voice conversion/cloning is unavailable. No guessed endpoint, request format, API-key input, proxy promise or success status is supplied.
- Calls/RTP/VoIP, video messages and existing imported audio are not connected to this PCM adapter.
- The UI uses functional ItemList controls and English labels; exact recovered visuals/localization and a standalone microphone/audio-preview UI are outside this slice. Telegram's normal voice-message preview hears the encoded effect.

## Files in this slice

Four `cleanroom/WhitegramVoice*.swift` runtime files, `voice_patches.py`, this document, and `tests/voice/{test_voice_patches.py,run_native.py,WhitegramVoiceDSPTests.swift}`. Runtime copying, main-menu routing, and invoking the modular patcher are parent integration steps.
