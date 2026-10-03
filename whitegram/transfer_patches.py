"""Original bounded multipart concurrency, including DC/CDN/reference transitions."""

from pathlib import Path

from source_patches import SourcePatches

TRANSFER_RUNTIME_FILES = {
    "WhitegramTransferSettings.swift": "submodules/TelegramCore/Sources/WhitegramTransferSettings.swift",
}
FETCH = "submodules/TelegramCore/Sources/Network/FetchV2.swift"
DISPATCH = "submodules/TelegramCore/Sources/Network/MultipartFetch.swift"
UPLOAD = "submodules/TelegramCore/Sources/Network/MultipartUpload.swift"


def _replace(patches: SourcePatches, path: str, before: str, after: str, count: int = 1) -> None:
    value = patches.read(path)
    applied = value.count(after)
    if applied and (applied != count or before in value.replace(after, "")):
        raise ValueError(f"transfer: {path}: ambiguous partially applied edit")
    patches.replace("transfer", path, before, after, count=count)


def transfer_patches(patches: SourcePatches) -> None:
    # All four original call sites use the policy, including refreshed file
    # references and CDN reuploads. The rest of FetchV2's range, encryption,
    # hash verification, priority and flood-wait state machine stays native.
    _replace(patches, FETCH, "maxPendingParts: 6,", "maxPendingParts: WhitegramTransferSettings.current.downloadParallelParts,", count=4)
    _replace(patches, DISPATCH,
             "    if network.useExperimentalFeatures, let _ = resource as? TelegramCloudMediaResource {\n",
             "    if network.useExperimentalFeatures || WhitegramTransferSettings.current.usesAcceleratedDownload, let _ = resource as? TelegramCloudMediaResource {\n")
    _replace(patches, UPLOAD, """        if increaseParallelParts {
            self.parallelParts = 30
        } else {
            self.parallelParts = 3
        }
""", """        self.parallelParts = WhitegramTransferSettings.current.uploadParallelParts(increaseParallelParts: increaseParallelParts)
""")


def apply_transfer_patches(root: Path) -> dict[str, list[str]]:
    patches = SourcePatches(root)
    transfer_patches(patches)
    return patches.write()
