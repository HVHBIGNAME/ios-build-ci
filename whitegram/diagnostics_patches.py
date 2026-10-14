"""Install diagnostic startup before the application UI is constructed."""

from appearance_parity_patches import replace
from source_patches import SourcePatches

DIAGNOSTICS_RUNTIME_FILES = {
    **{name + ".swift": "submodules/TelegramCore/Sources/" + name + ".swift" for name in (
        "WhitegramErrorReport", "WhitegramErrorReporter", "WhitegramDiagnosticsUpload",
    )},
    "WhitegramDiagnosticsLifecycle.swift": "submodules/TelegramUI/Sources/WhitegramDiagnosticsLifecycle.swift",
}
APP = "submodules/TelegramUI/Sources/AppDelegate.swift"


def apply_diagnostics_patches(root):
    patches = SourcePatches(root)
    before = "        let launchStartTime = CFAbsoluteTimeGetCurrent()\n"
    replace(patches, "automaticErrorReports", APP, before,
            "        WhitegramDiagnosticsLifecycle.shared.start()\n" + before)
    return patches.write()
