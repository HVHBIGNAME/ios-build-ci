"""Persist photo encoding choices in resources and configure native single-camera capture."""

from pathlib import Path

from source_patches import SourcePatches

MEDIA_RUNTIME_FILES = {
    "WhitegramMediaSettings.swift": "submodules/TelegramCore/Sources/WhitegramMediaSettings.swift",
    "WhitegramPhotoExport.swift": "submodules/LocalMediaResources/Sources/WhitegramPhotoExport.swift",
    "WhitegramPhotoMetadata.swift": "submodules/LocalMediaResources/Sources/WhitegramPhotoMetadata.swift",
    "WhitegramCameraConfiguration.swift": "submodules/Camera/Sources/WhitegramCameraConfiguration.swift",
    "WhitegramMediaSettingsController.swift": "submodules/SettingsUI/Sources/WhitegramMediaSettingsController.swift",
}
PICKER = "submodules/LegacyMediaPickerUI/Sources/LegacyMediaPickers.swift"
FETCH = "submodules/LocalMediaResources/Sources/FetchPhotoLibraryImageResource.swift"
CAMERA = "submodules/Camera/Sources/Camera.swift"
DEVICE = "submodules/Camera/Sources/CameraDevice.swift"
OUTPUT = "submodules/Camera/Sources/CameraOutput.swift"


def _replace(patches: SourcePatches, path: str, before: str, after: str) -> None:
    value = patches.read(path)
    applied = value.count(after)
    if applied and (applied != 1 or before in value.replace(after, "")):
        raise ValueError(f"media: {path}: ambiguous partially applied edit")
    patches.replace("media-camera", path, before, after)


def media_camera_patches(patches: SourcePatches) -> None:
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
                                            width: whitegramMedia.sendLargePhotos ? whitegramPhotoSide : nil, height: whitegramMedia.sendLargePhotos ? whitegramPhotoSide : nil,
                                            quality: whitegramMedia.sendLargePhotos ? Int32((whitegramMedia.photoCompressionQuality * 100.0).rounded()) : nil,
                                            forceHd: item.forceHd || whitegramMedia.alwaysSendHD)
''')
    anchor = "                                case let .tempFile(path):\n                                    var previewRepresentations: [TelegramMediaImageRepresentation] = []\n"
    _replace(patches, PICKER, anchor, '''                                case let .tempFile(originalPath):
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
    _replace(patches, PICKER, anchor, "                                    let resource = LocalFileReferenceMediaResource(localFilePath: path, randomId: randomId, isUniquelyReferencedTemporaryFile: path != originalPath)\n")
    anchor = "            subscriber.putNext(messages)\n"
    _replace(patches, PICKER, anchor, "            whitegramPhotosEnqueued = true\n" + anchor)
    anchor = "let data = compressImageToJPEG(scaledImage, quality: 0.6, tempFilePath: tempFile.path)"
    _replace(patches, FETCH, anchor, "let data = compressImageToJPEG(scaledImage, quality: Float(min(100, max(10, quality ?? 60))) / 100.0, tempFilePath: tempFile.path)")
    anchor = "                                let scaledImage = resizedImage(image, for: scaledSize)\n"
    _replace(patches, FETCH, anchor, "                                let scaledImage = max(size.width, size.height) > 2560.0 ? WhitegramPhotoExport.resizedUploadImage(image, size: scaledSize) : resizedImage(image, for: scaledSize)\n")
    anchor = "    private(set) var fps: Double = defaultFPS\n"
    _replace(patches, DEVICE, anchor, anchor + '''    private var whitegramFrameRate: Double?

    func configureWhitegramFormat(multiCam: Bool) {
        guard let device = self.videoDevice else { return }
        self.transaction(device) { device in
            self.whitegramFrameRate = WhitegramCameraConfiguration.apply(to: device, multiCam: multiCam, defaultFPS: self.fps, settings: .current)
            if let fps = self.whitegramFrameRate { self.fps = fps }
        }
    }
''')
    anchor = "        self.position = position\n"
    _replace(patches, DEVICE, anchor, anchor + "        self.whitegramFrameRate = nil\n")
    anchor = "        guard let device = self.videoDevice, let targetFPS = device.actualFPS(Double(fps)) else {\n"
    _replace(patches, DEVICE, anchor, "        guard let device = self.videoDevice, let targetFPS = device.actualFPS(self.whitegramFrameRate ?? fps) else {\n")
    anchor = "        self.input.configure(for: session, device: self.device, audio: audio && switchAudio)\n"
    _replace(patches, CAMERA, anchor, "        if self.exclusive { self.device.configureWhitegramFormat(multiCam: session.hasMultiCam) }\n" + anchor)
    anchor = "                self.positionValue = targetPosition\n"
    _replace(patches, CAMERA, anchor, anchor + "                if self.initialConfiguration.isRoundVideo { WhitegramMediaSettings.rememberCamera(front: targetPosition == .front) }\n")
    anchor = "            self.positionValue = position\n"
    _replace(patches, CAMERA, anchor, anchor + "            if self.initialConfiguration.isRoundVideo { WhitegramMediaSettings.rememberCamera(front: position == .front) }\n")
    anchor = "                AVVideoAverageBitRateKey: 1000 * 1000,\n"
    _replace(patches, OUTPUT, anchor, "                AVVideoAverageBitRateKey: WhitegramMediaSettings.current.roundVideoBitrateValue ?? (1000 * 1000),\n")


def apply_media_camera_patches(root: Path) -> dict[str, list[str]]:
    patches = SourcePatches(root)
    media_camera_patches(patches)
    return patches.write()
