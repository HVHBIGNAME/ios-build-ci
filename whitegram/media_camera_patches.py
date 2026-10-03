"""Evidence-backed media policies wired to native capture, enqueue and fetch APIs."""

from pathlib import Path

from source_patches import SourcePatches

MEDIA_RUNTIME_FILES = {
    "WhitegramMediaSettings.swift": "submodules/TelegramCore/Sources/WhitegramMediaSettings.swift",
    "WhitegramPhotoExport.swift": "submodules/LocalMediaResources/Sources/WhitegramPhotoExport.swift",
    "WhitegramPhotoMetadata.swift": "submodules/LocalMediaResources/Sources/WhitegramPhotoMetadata.swift",
    "WhitegramCameraConfiguration.swift": "submodules/Camera/Sources/WhitegramCameraConfiguration.swift",
    "WhitegramMediaSettingsController.swift": "submodules/SettingsUI/Sources/WhitegramMediaSettingsController.swift",
    "WhitegramPhotoQualitySliderItem.swift": "submodules/SettingsUI/Sources/WhitegramPhotoQualitySliderItem.swift",
}
CAMERA_RUNTIME_FILES = MEDIA_RUNTIME_FILES
PICKER = "submodules/LegacyMediaPickerUI/Sources/LegacyMediaPickers.swift"
FETCH = "submodules/LocalMediaResources/Sources/FetchPhotoLibraryImageResource.swift"
CAMERA = "submodules/Camera/Sources/Camera.swift"
DEVICE = "submodules/Camera/Sources/CameraDevice.swift"
OUTPUT = "submodules/Camera/Sources/CameraOutput.swift"
ROUND_SCREEN = "submodules/TelegramUI/Components/VideoMessageCameraScreen/Sources/VideoMessageCameraScreen.swift"
MEDIA_PICKER = "submodules/MediaPickerUI/Sources/MediaPickerScreen.swift"


def _replace(patches: SourcePatches, path: str, before: str, after: str, *, previous: str | None = None, count: int = 1) -> None:
    """Accept release source or the compiling baseline, but never mixed edits."""
    value = patches.read(path)
    variants = sorted(set([before] + ([previous] if previous is not None else [])), key=len, reverse=True)
    applied = value.count(after)
    if applied:
        if applied != count or any(anchor in value.replace(after, "") for anchor in variants):
            raise ValueError(f"media: {path}: ambiguous partially applied edit")
        patches.replace("media-camera", path, before, after, count=count)
        return
    for anchor in variants:
        if anchor in value:
            if value.count(anchor) != count or any(other in value.replace(anchor, "") for other in variants):
                raise ValueError(f"media: {path}: ambiguous baseline/release anchors")
            patches.replace("media-camera", path, anchor, after, count=count)
            return
    raise ValueError(f"media: {path}: missing anchor: {before[:120]!r}")


def media_camera_patches(patches: SourcePatches) -> None:
    _replace(patches, MEDIA_PICKER,
             '        let highQualityPhoto = UserDefaults.standard.bool(forKey: "TG_photoHighQuality_v0")\n',
             '        let highQualityPhoto = UserDefaults.standard.bool(forKey: "TG_photoHighQuality_v0") || WhitegramMediaSettings.current.alwaysSendHD\n')
    anchor = "            var messages: [LegacyAssetPickerEnqueueMessage] = []\n"
    _replace(patches, PICKER, anchor, anchor + '''            let whitegramMedia = WhitegramMediaSettings.current
            var whitegramPreparedPhotos: [String] = []
            var whitegramPhotosEnqueued = false
            defer {
                if !whitegramPhotosEnqueued {
                    for path in whitegramPreparedPhotos {
                        do { try FileManager.default.removeItem(atPath: path) }
                        catch { Logger.shared.log("WhitegramPhoto", "Temporary metadata-cleaned photo cleanup failed") }
                    }
                }
            }
''')
    anchor = "                                    let maxSize = item.forceHd ? CGSize(width: 2560.0, height: 2560.0) : CGSize(width: 1280.0, height: 1280.0)\n"
    _replace(patches, PICKER, anchor, '''                                    let whitegramPhotoSide = CGFloat(whitegramMedia.photoMaxDimension(hd: item.forceHd))
                                    let maxSize = CGSize(width: whitegramPhotoSide, height: whitegramPhotoSide)
''')
    anchor = "compressImageToJPEG(scaledImage, quality: 0.6, tempFilePath: tempFile.path)"
    _replace(patches, PICKER, anchor, "compressImageToJPEG(scaledImage, quality: Float(whitegramMedia.jpegQuality(default: 0.6)), tempFilePath: tempFile.path)")
    anchor = "                                        let scaledSize = size.aspectFittedOrSmaller(CGSize(width: 1280.0, height: 1280.0))\n                                        let resource = PhotoLibraryMediaResource(localIdentifier: asset.localIdentifier, uniqueId: Int64.random(in: Int64.min ... Int64.max), forceHd: item.forceHd)\n"
    _replace(patches, PICKER, anchor, '''                                        let whitegramPhotoSide = whitegramMedia.photoMaxDimension(hd: item.forceHd)
                                        let scaledSize = size.aspectFittedOrSmaller(CGSize(width: CGFloat(whitegramPhotoSide), height: CGFloat(whitegramPhotoSide)))
                                        let resource = PhotoLibraryMediaResource(localIdentifier: asset.localIdentifier, uniqueId: Int64.random(in: Int64.min ... Int64.max),
                                            width: whitegramPhotoSide, height: whitegramPhotoSide, quality: whitegramMedia.photoQualityPercent,
                                            forceHd: item.forceHd || whitegramMedia.alwaysSendHD || whitegramMedia.sendLargePhotos)
''', previous='''                                        let whitegramPhotoSide = whitegramMedia.photoMaxDimension(hd: item.forceHd)
                                        let scaledSize = size.aspectFittedOrSmaller(CGSize(width: CGFloat(whitegramPhotoSide), height: CGFloat(whitegramPhotoSide)))
                                        let resource = PhotoLibraryMediaResource(localIdentifier: asset.localIdentifier, uniqueId: Int64.random(in: Int64.min ... Int64.max),
                                            width: whitegramMedia.sendLargePhotos ? whitegramPhotoSide : nil, height: whitegramMedia.sendLargePhotos ? whitegramPhotoSide : nil,
                                            quality: whitegramMedia.sendLargePhotos ? Int32((whitegramMedia.photoCompressionQuality * 100.0).rounded()) : nil,
                                            forceHd: item.forceHd || whitegramMedia.alwaysSendHD)
''')
    _replace(patches, PICKER,
             "                                    let resource = PhotoLibraryMediaResource(localIdentifier: asset.localIdentifier, uniqueId: Int64.random(in: Int64.min ... Int64.max))\n",
             '''                                    let whitegramPhotoSide = whitegramMedia.photoMaxDimension(hd: false)
                                    let resource = PhotoLibraryMediaResource(localIdentifier: asset.localIdentifier, uniqueId: Int64.random(in: Int64.min ... Int64.max),
                                        width: whitegramPhotoSide, height: whitegramPhotoSide, quality: whitegramMedia.photoQualityPercent,
                                        forceHd: whitegramMedia.alwaysSendHD || whitegramMedia.sendLargePhotos)
''')
    anchor = "                                case let .tempFile(path):\n                                    var previewRepresentations: [TelegramMediaImageRepresentation] = []\n"
    _replace(patches, PICKER, anchor, '''                                case let .tempFile(originalPath):
                                    let path: String
                                    if whitegramMedia.cleanMetadataOnSend {
                                        do {
                                            if let cleanedPath = try WhitegramPhotoMetadata.cleanedCopyIfSupported(path: originalPath, mimeType: mimeType) {
                                                path = cleanedPath
                                                whitegramPreparedPhotos.append(path)
                                            } else {
                                                path = originalPath
                                            }
                                        } catch {
                                            Logger.shared.log("WhitegramPhoto", "Metadata cleaning failed; cancelling this selection")
                                            subscriber.putError(Void())
                                            return
                                        }
                                    } else {
                                        path = originalPath
                                    }
                                    var previewRepresentations: [TelegramMediaImageRepresentation] = []
''', previous='''                                case let .tempFile(originalPath):
                                    let path: String
                                    if whitegramMedia.cleanMetadataOnSend && WhitegramPhotoMetadata.supportsMetadataCleaning(mimeType: mimeType) {
                                        do {
                                            path = try WhitegramPhotoMetadata.cleanedCopy(path: originalPath)
                                            whitegramPreparedPhotos.append(path)
                                        } catch {
                                            subscriber.putError(Void())
                                            return
                                        }
                                    } else {
                                        path = originalPath
                                    }
                                    var previewRepresentations: [TelegramMediaImageRepresentation] = []
''')
    anchor = "                                    let resource = LocalFileReferenceMediaResource(localFilePath: path, randomId: randomId)\n"
    _replace(patches, PICKER, anchor, '''                                    let whitegramFileSize = engineFileSize(path)
                                    let resource: TelegramMediaResource
                                    if path != originalPath {
                                        let cleanedResource = LocalFileMediaResource(fileId: randomId, size: whitegramFileSize)
                                        account.postbox.mediaBox.moveResourceData(cleanedResource.id, fromTempPath: path)
                                        whitegramPreparedPhotos.removeAll(where: { $0 == path })
                                        resource = cleanedResource
                                    } else {
                                        resource = LocalFileReferenceMediaResource(localFilePath: path, randomId: randomId)
                                    }
''', previous="                                    let resource = LocalFileReferenceMediaResource(localFilePath: path, randomId: randomId, isUniquelyReferencedTemporaryFile: path != originalPath)\n")
    _replace(patches, PICKER, "mimeType: mimeType, size: engineFileSize(path), attributes: [.FileName(fileName: name)]", "mimeType: mimeType, size: whitegramFileSize, attributes: [.FileName(fileName: name)]")
    _replace(patches, PICKER,
             "conversion: asFile ? .passthrough : .compress(resourceAdjustments)",
             "conversion: whitegramMedia.shouldCompressLibraryVideo(asFile: asFile) ? .compress(resourceAdjustments) : .passthrough")
    anchor = "            subscriber.putNext(messages)\n"
    _replace(patches, PICKER, anchor, "            whitegramPhotosEnqueued = true\n" + anchor)
    anchor = "let data = compressImageToJPEG(scaledImage, quality: 0.6, tempFilePath: tempFile.path)"
    _replace(patches, FETCH, anchor, "let data = compressImageToJPEG(scaledImage, quality: whitegramMedia.photoLibraryJPEGQuality(storedQuality: quality), tempFilePath: tempFile.path)", previous="let data = compressImageToJPEG(scaledImage, quality: Float(min(100, max(10, quality ?? 60))) / 100.0, tempFilePath: tempFile.path)")
    _replace(patches, FETCH, "        let queue = ThreadPoolQueue(threadPool: fetchPhotoWorkers)\n", "        let queue = ThreadPoolQueue(threadPool: fetchPhotoWorkers)\n        let whitegramMedia = WhitegramMediaSettings.current\n")
    _replace(patches, FETCH, '''            let size: CGSize
            if let width, let height {
                size = CGSize(width: CGFloat(width), height: CGFloat(height))
            } else {
                if hd {
                    size = CGSize(width: 2560.0, height: 2560.0)
                } else {
                    size = CGSize(width: 1280.0, height: 1280.0)
                }
            }
''', '''            let whitegramTarget = whitegramMedia.photoLibraryTargetDimensions(width: width, height: height, hd: hd)
            let size = CGSize(width: CGFloat(whitegramTarget.width), height: CGFloat(whitegramTarget.height))
''')
    anchor = "                                let scaledImage = resizedImage(image, for: scaledSize)\n"
    _replace(patches, FETCH, anchor, "                                let scaledImage = max(size.width, size.height) > 2560.0 ? WhitegramPhotoExport.resizedUploadImage(image, size: scaledSize) : resizedImage(image, for: scaledSize)\n")
    anchor = "    private(set) var fps: Double = defaultFPS\n"
    _replace(patches, DEVICE, anchor, anchor + '''    private var whitegramFrameRate: Double?

    func configureWhitegramFormat(multiCam: Bool, policy: WhitegramMediaSettings.CapturePolicy?) {
        guard let device = self.videoDevice, let policy else { return }
        self.transaction(device) { device in
            self.whitegramFrameRate = WhitegramCameraConfiguration.apply(to: device, multiCam: multiCam, policy: policy)
            if let fps = self.whitegramFrameRate { self.fps = fps }
        }
    }
''', previous=anchor + '''    private var whitegramFrameRate: Double?

    func configureWhitegramFormat(multiCam: Bool) {
        guard let device = self.videoDevice else { return }
        self.transaction(device) { device in
            self.whitegramFrameRate = WhitegramCameraConfiguration.apply(to: device, multiCam: multiCam, defaultFPS: self.fps, settings: .current)
            if let fps = self.whitegramFrameRate { self.fps = fps }
        }
    }
''')
    anchor = "        self.position = position\n"
    _replace(patches, DEVICE, anchor, anchor + "        self.whitegramFrameRate = nil\n        self.fps = defaultFPS\n", previous=anchor + "        self.whitegramFrameRate = nil\n")
    anchor = "            if let targetFPS = device.actualFPS(maxFramerate) {\n"
    _replace(patches, DEVICE, anchor, anchor + "                self.fps = targetFPS.fps\n")
    anchor = "        guard let device = self.videoDevice, let targetFPS = device.actualFPS(Double(fps)) else {\n"
    _replace(patches, DEVICE, anchor, "        guard let device = self.videoDevice, let targetFPS = device.actualFPS(self.whitegramFrameRate ?? fps) else {\n")
    anchor = "        self.input.configure(for: session, device: self.device, audio: audio && switchAudio)\n"
    _replace(patches, CAMERA, anchor, '''        let whitegramSettings = WhitegramMediaSettings.current
        let whitegramPolicy = whitegramSettings.capturePolicy(front: position == .front, isRoundVideo: self.isRoundVideo, exclusive: self.exclusive, additional: self.additional, preferWide: preferWide, preferLowerFramerate: preferLowerFramerate)
        self.device.configureWhitegramFormat(multiCam: session.hasMultiCam, policy: whitegramPolicy)
''' + anchor, previous="        if self.exclusive { self.device.configureWhitegramFormat(multiCam: session.hasMultiCam) }\n" + anchor)
    _replace(patches, CAMERA, "        self.device.resetZoom(neutral: self.exclusive || !self.additional)\n", '''        var whitegramWideAngle = false
        if self.isRoundVideo && position == .back && whitegramSettings.roundCameraWideAngle {
            whitegramWideAngle = self.device.videoDevice.map { WhitegramCameraConfiguration.supportsWideAngle($0) } ?? false
            if !whitegramWideAngle {
                Logger.shared.log("WhitegramCamera", "Ultra-wide video-message capture is unavailable on the selected device")
            }
        }
        self.device.resetZoom(neutral: !whitegramWideAngle && (self.exclusive || !self.additional))
''')
    anchor = "    public static func isDualCameraSupported(forRoundVideo: Bool = false) -> Bool {\n"
    _replace(patches, CAMERA, anchor, anchor + "        if forRoundVideo && WhitegramMediaSettings.current.requiresSingleCameraForRoundVideo { return false }\n")
    anchor = "    public func setDualCameraEnabled(_ enabled: Bool, change: Bool = true) {\n"
    _replace(patches, CAMERA, anchor, anchor + "        let enabled = enabled && self.session.supportsDualCam\n")
    # Without the dual-mode check these three upstream paths address the absent
    # additional camera when a custom round session uses the front camera alone.
    _replace(patches, CAMERA, "        if self.initialConfiguration.isRoundVideo {\n            if self.positionValue == .front {\n", "        if self.initialConfiguration.isRoundVideo && self.isDualCameraEnabled == true {\n            if self.positionValue == .front {\n", count=3)
    anchor = "            self.positionValue = targetPosition\n"
    # Match the complete dual-camera branch, not the indented single-camera one.
    _replace(patches, CAMERA, anchor + "            self._positionPromise.set(targetPosition)\n", anchor + "            if self.initialConfiguration.isRoundVideo { WhitegramMediaSettings.rememberCamera(front: targetPosition == .front) }\n            self._positionPromise.set(targetPosition)\n")
    anchor = "                self.positionValue = targetPosition\n"
    _replace(patches, CAMERA, anchor, anchor + "                if self.initialConfiguration.isRoundVideo { WhitegramMediaSettings.rememberCamera(front: targetPosition == .front) }\n")
    anchor = "            self.positionValue = position\n"
    _replace(patches, CAMERA, anchor, anchor + "            if self.initialConfiguration.isRoundVideo { WhitegramMediaSettings.rememberCamera(front: position == .front) }\n")
    _replace(patches, CAMERA,
             "return mainDeviceContext.output.startRecording(mode: .roundVideo, orientation:",
             "return mainDeviceContext.output.startRecording(mode: .roundVideo, position: self.positionValue, orientation:")
    _replace(patches, CAMERA, '''                    disposable.set(context.startRecording().start(next: { value in
                        subscriber.putNext(value)
                    }, completed: {
                        subscriber.putCompletion()
                    }))
''', '''                    disposable.set(context.startRecording().start(next: { value in
                        subscriber.putNext(value)
                    }, error: { error in
                        subscriber.putError(error)
                    }, completed: {
                        subscriber.putCompletion()
                    }))
''')
    # The upstream output defaults to .front. Initial back-camera selection must
    # also reach the compositor; otherwise it mirrors the back image (single)
    # or records the front stream despite the back preview (dual).
    anchor = "        if case .roundVideo = mode {\n            dimensions = videoMessageDimensions.cgSize\n"
    _replace(patches, OUTPUT, anchor, '''        if case .roundVideo = mode {
            self.currentPosition = position ?? .front
            self.lastSwitchTimestamp = 0.0
            self.needsCrossfadeTransition = false
            self.crossfadeTransitionStart = 0.0
            self.needsSwitchSampleOffset = false
            self.lastAudioSampleTime = nil
            self.videoSwitchSampleTimeOffset = nil
            dimensions = videoMessageDimensions.cgSize
''')
    anchor = "                AVVideoAverageBitRateKey: 1000 * 1000,\n"
    _replace(patches, OUTPUT, anchor, "                AVVideoAverageBitRateKey: WhitegramMediaSettings.current.roundVideoBitrateValue ?? (1000 * 1000),\n                AVVideoExpectedSourceFrameRateKey: self.whitegramCaptureFPS,\n", previous="                AVVideoAverageBitRateKey: WhitegramMediaSettings.current.roundVideoBitrateValue ?? (1000 * 1000),\n")
    _replace(patches, OUTPUT, '''            if orientation == .landscapeLeft || orientation == .landscapeRight {
                dimensions = CGSize(width: 1920, height: 1080)
            } else {
                dimensions = CGSize(width: 1080, height: 1920)
            }
            guard let settings = self.videoOutput.recommendedVideoSettings(forVideoCodecType: codecType, assetWriterOutputFileType: .mp4) else {
                return .complete()
            }
            videoSettings = settings
''', '''            guard var settings = self.videoOutput.recommendedVideoSettings(forVideoCodecType: codecType, assetWriterOutputFileType: .mp4),
                  let captureDimensions = self.whitegramCaptureDimensions,
                  let whitegramDimensions = WhitegramMediaSettings.videoRecordingDimensions(encodedWidth: Int(captureDimensions.width), encodedHeight: Int(captureDimensions.height), portrait: orientation == .portrait || orientation == .portraitUpsideDown) else {
                Logger.shared.log("WhitegramCamera", "Invalid video capture dimensions or encoder settings")
                return .fail(.videoRecorderInitializationError)
            }
            settings[AVVideoWidthKey] = Int(captureDimensions.width)
            settings[AVVideoHeightKey] = Int(captureDimensions.height)
            var compressionProperties = (settings[AVVideoCompressionPropertiesKey] as? [String: Any]) ?? [:]
            compressionProperties[AVVideoExpectedSourceFrameRateKey] = self.whitegramCaptureFPS
            settings[AVVideoCompressionPropertiesKey] = compressionProperties
            dimensions = CGSize(width: CGFloat(whitegramDimensions.width), height: CGFloat(whitegramDimensions.height))
            videoSettings = settings
''')
    anchor = "    var hasAudio: Bool = false\n"
    _replace(patches, OUTPUT, anchor, anchor + "    private var whitegramCaptureFPS: Double = 30.0\n    private var whitegramCaptureDimensions: CMVideoDimensions?\n", previous=anchor + "    private var whitegramCaptureFPS: Double = 30.0\n")
    anchor = "    func configure(for session: CameraSession, device: CameraDevice, input: CameraInput, previewView: CameraSimplePreviewView?, audio: Bool, photo: Bool, metadata: Bool) {\n"
    _replace(patches, OUTPUT, anchor, anchor + "        self.whitegramCaptureFPS = min(60.0, max(1.0, device.fps))\n        self.whitegramCaptureDimensions = device.videoDevice.map { CMVideoFormatDescriptionGetDimensions($0.activeFormat.formatDescription) }\n", previous=anchor + "        self.whitegramCaptureFPS = min(60.0, max(1.0, device.fps))\n")
    _replace(patches, ROUND_SCREEN, "                camera.rampZoom(1.0, rate: 8.0)\n", "                if !WhitegramMediaSettings.current.staticZoomEnabled {\n                    camera.rampZoom(1.0, rate: 8.0)\n                }\n")
    for method, argument, validation in [("setZoomLevel", "zoomLevel", "zoomLevel.isFinite"), ("setZoomDelta", "zoomDelta", "zoomDelta.isFinite && zoomDelta > 0.0")]:
        anchor = f"    func {method}(_ {argument}: CGFloat) {{\n"
        _replace(patches, DEVICE, anchor, anchor + f"        guard {validation} else {{ return }}\n")
    anchor = "    func rampZoom(_ zoomLevel: CGFloat, rate: CGFloat) {\n"
    _replace(patches, DEVICE, anchor, anchor + "        guard zoomLevel.isFinite, rate.isFinite, rate > 0.0 else { return }\n")


def apply_media_camera_patches(root: Path) -> dict[str, list[str]]:
    patches = SourcePatches(root)
    media_camera_patches(patches)
    return patches.write()


apply_camera_patches = apply_media_camera_patches
