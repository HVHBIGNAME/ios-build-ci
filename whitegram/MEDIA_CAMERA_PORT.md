# Media, camera and transfer parity

Role: `camera`. Native consumers and source checks are implemented in the recovered durable checkout. The parent has added the transfer installer, archive/default changes and legacy-camera bridge. Remaining route integration and Apple/device validation are listed below; this is not a whole-client parity claim.

## Original evidence

The original IPA SHA-256 is `bd6d3a13046d5857c1389e2d794c4c2ca44cee89bb22880004bd77f84fe29837`. The audit `images` table identifies TelegramCore as **46**, TelegramUI as **55**. Focused disassembly and decoded data are under:

`C:\coding\telegram\whitegram\recovery_20261002\campaign\camera`

`wgtool audit-function` verifies the IPA hash before each export. Recovered exports have provenance in the campaign's `recovery-manifest.json`. `read_constants.py` independently verifies the same hash and decodes the referenced numeric table, migration-key strings and ImageIO/AVFoundation import slots into `constants.json`. New post-recovery exports include `core-0x200438.asm`, `ui-0xddc85c.asm`, `ui-0x2825b28.asm`, `ui-0x28f28e4.asm` and `ui-0x28f41e4.asm`. The latter includes the complete recorder initialization region `0x28f3de0..0x28f4b98`. Existing getter assembly is under the read-only recovery root's `recovered-3.1.1/native/TelegramCoreFramework-0/assembly`.

The ready reference is `C:\coding\telegram\whitegram\source-12.9.2`, source revision `6ad963e5b62d354da79040f388ae2b9132fb17b8`, public revision `db18308774f863074278feedc4df4507b0fb174e`, baseline overlay `dba65e0a2c3b573f5f92a68807b9bc5771e6514c`. Its readiness is recorded in `campaign/reference-ready.json`. Tests use in-memory `SourcePatches` and read-only `git show`; they do not apply the candidate to that reference.

| Behavior | Original evidence | Recovered policy |
| --- | --- | --- |
| Camera preset values/default | UI `0xcab938`; Core `0x200690`, `0x2007c4`, outlined default `0x213448` | `4k`, `1080p`, `720p`; both sides default to `1080p` |
| Camera FPS | UI `0xcaba64`; Core `0x2008f8`, `0x2009fc` | 30 or 60; both sides default to 30 |
| Stock/custom migration | Core `0x200438`, six strings at `0x1143778` | Absent an explicit choice: stock if none of the six camera keys exist, custom if any exist |
| Mode-dependent capture limits | UI `0x28e7a1c`, `0x28e7c14` | Additional camera or exclusive wide preview: 1920×1440; exclusive round: 640×480 sensor limit; additional/lower-rate capture: 30 FPS; dual main capture uses the selected 720p/1080p branch even when wide preview is requested |
| Single-camera round session | UI `0x28ecbcc` | Custom mode with either 4K preset, either FPS above 30, or wide-angle enabled forces a single-camera round session |
| Wide angle | UI `0x28e7884`, device configuration `0x28ef5ac`, zoom reset `0x28efbec` | Round/back camera starts at minimum available zoom rather than the virtual device's neutral wide-camera factor |
| Static zoom | UI `0x115cc44` | Continue applying pinch deltas; omit the ending/cancelled gesture's ramp back to 1.0 when enabled |
| Remember camera | UI `0x1157208` | Persist the switched front/back choice only when remember-last-camera is enabled |
| Round-video bitrate | Core `0x200d70`; UI `0xcabb30`, `0x28f41e4`, `0x28f4b14` | Default `medium`; low/medium/high = 500,000 / 1,000,000 / 3,000,000 bit/s; stock = 1,000,000 |
| Round output | UI `0x28f43d4` and `0x28f43f8` | 400×400; sensor presets do not enlarge the final round frame |
| Regular-video encoder | UI `0x28f2968..0x28f29a8`, `0x28f3f9c..0x28f40b8`, `0x28f44ac..0x28f452c` | Capture active-format dimensions and FPS; override recommended encoder width/height and source-FPS hint; swap result dimensions for portrait orientation |
| Photo quality | Core `0x202784`, double at `0xd62180`; UI `0x31cb588`, float at `0x4951f88`; slider block `0xddc85c..0xddc8fc` | Default 0.7; slider 10–100%; Photos-library JPEG consumer uses it for ordinary and large photos |
| Large photos | UI `0x31ca954..0x31ca978` | `hd || sendLargePhotos` selects 2560; otherwise 1280; no enlargement of small images |
| Always HD | UI `0x1f61c4c..0x1f61c74` | Native remembered photo-quality choice OR `alwaysSendHD` initializes picker HD mode |
| Still-file metadata | UI `0x2825b28`, call at `0x2830a78` | Probe the file with ImageIO; single-image export preserves orientation; JPEG recompression quality 0.95 |
| Photos video-as-file metadata | UI `0x282f7a0..0x282f83c` | Use `.compress(adjustments)` rather than `.passthrough` when cleaning is enabled |
| Download concurrency | Core `0x178644`, table at `0xd5f708`; callers `0x175fb8`, `0x179784`, `0x1798a8`, `0x17a1ac` | Modes 1/2/3 = 4/8/16; mode 0 uses 16 with `maxDownloadSpeed`, otherwise 6 |
| Upload concurrency | Core `0x199d00..0x199e00` | Explicit `increaseParallelParts` = 30; otherwise `sendAccelerationEnabled || maxDownloadSpeed` = 16, else 3 |

## Implementation

### Camera

`WhitegramMediaSettings` reads canonical preferences first, then the original `wg_` primitives. It validates numeric types and finite values, migrates old AVFoundation preset spellings on read, and preserves the compiling baseline's saved 24 FPS, 640×480, and bounded numeric bitrate selections. Those compatibility choices are distinct from the original menu's options.

`CameraDeviceContext.configure` passes the mode-specific policy to `CameraDevice` inside the existing capture-session transaction. Active format and frame durations are changed only under the native device lock. Validation checks video/pixel subtype, excludes photo-only formats, checks the requested frame-rate range, and checks `isMultiCamSupported` against the actual session. Unsupported formats retain native capture configuration and are logged. The settings screen probes the exclusive sensor's formats, rather than filtering all choices through MultiCam and hiding valid single-session 4K/60 options. It marks unavailable sensor combinations; the help explains the additional per-session limits.

The original single-camera predicate affects `CameraSession` creation through `Camera.isDualCameraSupported`. Dual mode is additionally constrained to the session's actual capability. The front-camera zoom routing also checks whether dual mode is active, so single-front round capture addresses the existing main device. Pinch inputs reject non-finite values; zoom remains clamped by the existing native/compat device limits.

Wide angle uses the selected virtual camera's ultra-wide constituent/minimum zoom, preserving native device selection and switching behavior. Devices without the required constituent show an unavailable message and log the fallback. Remember-last-camera covers both native single-camera switches and dual-camera position changes. The selected initial position is also passed into the round recorder's compositor before capture starts: the upstream hardcoded front state otherwise mirrors an initial back image in single mode or selects the front stream in dual mode. Per-recording transition/timestamp state is reset at that point.

The round encoder consumes the selected H.264 bitrate and an explicit source-frame-rate hint taken from validated device FPS. The native 400×400 filter/format-description/output pipeline remains the frame-size contract. The original mode restrictions still apply; selecting 60 FPS does not promise a 60 FPS round recording when the round context requests the lower-rate path.

Regular video now also captures the **actual active format** after configuration, writes that width/height and FPS into the recommended encoder settings, and reports orientation-correct dimensions in `VideoCaptureResult`. The upstream fixed 1080p result and unmodified recommended dimensions were insufficient for 720p/4K selections. `WhitegramMediaSettings.videoRecordingDimensions` bounds and rotates this result; a missing/invalid capture format fails recorder initialization rather than returning a misleading size. The public `Camera.startRecording` adapter now forwards initialization errors from the inner signal instead of dropping them.

The controller uses verified original `camera.settings.*`, photo, metadata, remember/static-zoom and acceleration strings through `WhitegramLocalization`, including Russian, Ukrainian, English and custom packs. Preference/pack changes refresh the open list. Supplemental port-bound and fallback explanations are separately authored in those three languages. Download mode 0 displays its effective 16-part legacy override when the maximum-speed switch is enabled, rather than claiming the six-part default is active.

### Photos and metadata

New large/HD images use 2560 pixels, standard images use 1280. The picker initializes HD visibly. Photo-library image and file enqueue branches persist dimensions and JPEG quality in their native `PhotoLibraryMediaResource`, so changing preferences does not change those queued resources. Explicit dimensions up to 4096 remain accepted for resources already queued by the baseline. Invalid or partial resource dimensions use the bounded current default.

Photo-library JPEG quality applies regardless of large-photo mode. The baseline's prepared-UIImage large-photo quality behavior is retained; ordinary prepared-UIImage encoding keeps its native 0.6 default. JPEG XL continues using its own native quality/encoding path.

The still-file cleaner probes actual ImageIO content, including files with generic MIME labels, and preserves orientation, dimensions and color profile. It first attempts the baseline's lossless metadata replacement for JPEG/PNG/HEIC/HEIF. The result is verified for GPS, IPTC, EXIF/EXIF auxiliary, TIFF, PNG text, and extra XMP tags. If the codec cannot provide a verified copy, it rebuilds from pixels, using the original 0.95 JPEG policy. Other writable single-image ImageIO formats use the rebuild path. Input is bounded to 128 MiB; fallback pixel decoding is bounded to 64 megapixels. These are explicit port resource limits, not recovered original limits.

An unsupported animated/multipage image or non-image document follows its native path. A corrupt supported image or failed cleanup aborts the selection, rather than uploading an uncleaned fallback. Verified new files are moved into `MediaBox` ownership before message delivery; source files are never removed. Preparation failures dispose remaining unowned copies.

For Photos-library videos sent as files, the cleaning decision is persisted in `VideoLibraryMediaResource.conversion`. Its existing fetcher feeds the native video converter/asset writer rather than copying the source container. That pipeline preserves its normal transform/color handling and can change file size/quality. The audited original's two cleanup hooks are now covered. General document formats and arbitrary temporary video files are not an all-formats metadata scrubber.

### Transfers

`WhitegramTransferSettings` implements the exact 4/8/16 download table and 3/16/30 upload precedence with strict, bounded preference decoding. `transfer_patches.py` wires all four FetchV2 state-creation sites (initial DC, CDN, reference refresh, CDN reupload) and `MultipartUploadManager` initialization.

An explicit acceleration selection routes supported `TelegramCloudMediaResource` downloads through the already available V2 implementation even when `network.useExperimentalFeatures` is off. This is a port integration adaptation necessary for the control to have a consumer in ordinary builds. Native/default selection retains the original dispatcher behavior; V1-only resources keep their native implementation. Part sizes, alignment, secret-file encryption, CDN hashes, upload headers, priorities, cancellation, resource references and server flood-wait handling remain owned by the native transfer state machines.

## Parent integration

1. Keep installing the complete `MEDIA_RUNTIME_FILES` and `TRANSFER_RUNTIME_FILES` maps. Both are now present in parent-owned `compat-12.9.4.py`. Copy the latest `WhitegramMediaSettings.swift` together with the latest camera hooks: the regular recorder calls its new `videoRecordingDimensions(encodedWidth:encodedHeight:portrait:)` helper. `CAMERA_RUNTIME_FILES` and `apply_camera_patches` remain aliases.
2. The parent now calls `apply_transfer_patches(source_root)` beside `apply_media_camera_patches(source_root)`, after runtime installation. The two modules touch disjoint native files and can instead share a `SourcePatches` transaction via `media_camera_patches(patches)` and `transfer_patches(patches)`. Both orders and replay are tested. Each writing entrypoint validates its complete component before calling `write()`. Keep the baseline native camera/filter/zoom compatibility fixes.
3. `WhitegramMediaSettingsController` includes camera, photo and transfer controls. Its entrypoint remains **`whitegramMediaSettingsController(context:)`**. At the last source read, `staticZoom`, `maxDownloadSpeed`, `sendAcceleration`, and `downloadAccelPicker` still needed routing to the `media` capability. Canonical keys are `staticZoomEnabled`, `maxDownloadSpeed`, `sendAccelerationEnabled`, and `downloadAccelMode`; `photoQualitySlider` maps to `photoCompressionQuality`. The controls already work when the media controller is reached through an existing camera/photo row.
4. Parent source now contains the 0.7 generated photo default, Boolean `roundCameraWideAngle`, integer `downloadAccelMode` `0...3`, and `low`/`medium`/`high` bitrate choices alongside earlier numeric choices. Preserve explicitly saved quality/FPS/preset/bitrate values. Advanced camera keys are read lazily from the canonical dictionary or original `wg_` primitives; absence must keep the six-key stock/custom inference.
5. Parent source now uses `WhitegramMediaSettings.current.videoMessageCamera` in `WhitegramForkBridge.chat` before startup save. This closes the identified source-level legacy-selection overwrite; its launch/device migration check remains pending.
6. Required dependencies: TelegramCore uses Foundation/CoreFoundation and provides parent-owned `WhitegramPreferences`; Camera uses TelegramCore/AVFoundation; LocalMediaResources uses UIKit/ImageIO and its existing TelegramCore dependency; SettingsUI uses AccountContext, Camera, TelegramCore, ItemListUI, Display, AsyncDisplayKit, SwiftSignalKit, PresentationDataUtils and TelegramPresentationData. The controller also requires the parent localization runtime in TelegramCore (`WhitegramLocalization`, `WhitegramLocalizationStore` and their pack/string dependencies). LegacyMediaPickerUI, MediaPickerUI and VideoMessageCameraScreen use their existing TelegramCore imports. No new third-party SDK is required.

| Runtime source | Native destination |
| --- | --- |
| `WhitegramMediaSettings.swift` | `submodules/TelegramCore/Sources/WhitegramMediaSettings.swift` |
| `WhitegramTransferSettings.swift` | `submodules/TelegramCore/Sources/WhitegramTransferSettings.swift` |
| `WhitegramCameraConfiguration.swift` | `submodules/Camera/Sources/WhitegramCameraConfiguration.swift` |
| `WhitegramPhotoExport.swift` | `submodules/LocalMediaResources/Sources/WhitegramPhotoExport.swift` |
| `WhitegramPhotoMetadata.swift` | `submodules/LocalMediaResources/Sources/WhitegramPhotoMetadata.swift` |
| `WhitegramMediaSettingsController.swift` | `submodules/SettingsUI/Sources/WhitegramMediaSettingsController.swift` |
| `WhitegramPhotoQualitySliderItem.swift` | `submodules/SettingsUI/Sources/WhitegramPhotoQualitySliderItem.swift` |

## Checks and remaining validation

Windows source check command (run from `whitegram/tests`):

```powershell
$env:WHITEGRAM_ASSEMBLED_SOURCE = 'C:\coding\telegram\whitegram\source-12.9.2'
& 'C:\coding\telegram\whitegram\whitegram-check-env\Scripts\python.exe' -B -m unittest test_media_camera_patches test_transfer_patches -v
```

Checks cover new Swift parsing, real pristine-release and assembled-source replay, combined camera/transfer transaction order, all DC/CDN upload/download consumers, unchanged native encryption/cancellation/backpressure bodies, missing/duplicate/mixed-anchor failures before writes, queued photo option persistence, cleaned-resource ownership, initial back-camera compositor state, active-format encoder/result dimensions, native mode/zoom wiring, localization keys/observers and unchanged reference files. The final result is recorded in `parity/camera.json`.

On macOS, run `python3 -B whitegram/tests/media/run_native.py`. It packages the production Foundation/ImageIO files in a unique disposable test directory. Fixtures cover each original migration key, legacy camera/reset precedence, dual/exclusive policy, regular encoder dimensions, all transfer modes/precedence, JPEG GPS/EXIF/IPTC removal with non-empty input assertions, all eight EXIF orientations with decoded-pixel comparisons, PNG color/text, TIFF fallback, animation/corruption and the 128 MiB bound. The runner explicitly rejects non-Apple hosts. These native tests and a full iOS build **have not been run in this Windows role session**.

Device validation: supported/unsupported front/back 720p/1080p/4K at 30/60; actual regular encoder/result dimensions and orientation; native/MultiCam fallback; single-camera round-session selection; 0.5× ultra-wide availability; front/back pinch and static-zoom release/cancel; remember-last-camera across launches and original preference migration; 400×400 H.264 bitrate/source-FPS output and A/V timing across switches; HEIC/HDR orientation/color and metadata cleanup; Photos/iCloud video-as-file conversion; upload/download cancellation, resume, encryption, CDN integrity and server throttling in each mode; controller layout and live localization on-device. Local development sent no user media to live services.
