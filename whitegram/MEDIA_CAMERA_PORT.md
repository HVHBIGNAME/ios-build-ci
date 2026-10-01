# Media and camera

The main Camera category and recovered media/catalog rows open the connected media settings screen.

## Connected behavior

- `sendLargePhotos`: the standard photo enqueue path allows up to 4096 pixels on the longest side. Photo-library resources store their width, height and JPEG quality so later setting changes do not alter an already queued photo.
- `alwaysSendHD`: uses the existing 2560-pixel HD path. Existing smaller images are not enlarged.
- `photoCompressionQuality`: 10–100% JPEG quality for the large-photo path, including the photo-library fetch encoder.
- `cleanMetadataOnSend`: static JPEG/PNG/HEIC/HEIF temporary file selections use a new metadata-cleaned upload copy, limited to 128 MiB. Orientation/dimensions/color profile are checked; failure aborts that selection. Originals are not edited. The resource owns the new temporary file, and preparation failures clean up newly created copies.
- `videoMessageCamera` and `rememberLastCamera`: the selection uses the existing public-fork bridge, and actual round-video camera switches persist the chosen front/back camera.
- `useTelegramCameraSettings`, front/back capture presets and FPS: custom single-camera sensor configuration is applied inside the native device configuration lock. Unsupported formats retain the native configuration. Dual-camera contexts retain Telegram settings.
- `roundVideoBitrate`: selected round-video bitrate reaches the native H.264 encoder. The final square video-message dimensions are unchanged.

Original camera method evidence is in the coverage audit (`backPresetChanged` 0xcab8c8, `backFPSChanged` 0xcab900, `frontPresetChanged` 0xcaba2c, `frontFPSChanged` 0xcabaa8, `bitrateChanged` 0xcabc24). Preset names use AVFoundation identifiers. The 4096 limit, quality range, offered FPS choices and bitrate limits are explicit reconstructed policies; exact original numeric behavior is not claimed.

## Boundaries and checks

This increment does not implement wide-angle selection, static zoom, transfer acceleration or metadata cleaning for every document/asset path. The normal photo encoder already drops much metadata; raw-file cleaning covers the explicit temporary-image file branch. GIF/multi-image/video files retain their separate native paths.

`media_camera_patches.py` modifies the actual enqueue, photo fetch, camera device/context and round-video encoder files with counted/idempotent anchors. Local tests parse all new/patched Swift and check resource persistence, failure handling and replay. `tests/media/run_native.py` executes the Foundation policy and real ImageIO JPEG metadata tests on macOS. Camera hardware, preview orientation, sensor formats and end-to-end media sending still require device validation.
