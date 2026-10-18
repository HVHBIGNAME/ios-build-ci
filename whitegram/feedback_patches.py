"""Restore the 3.1.1 send-button impact verified at UI 0x27f7180..0x27f7198."""

from pathlib import Path

from source_patches import SourcePatches


PANEL = "submodules/TelegramUI/Components/Chat/ChatTextInputPanelNode/Sources/ChatTextInputPanelNode.swift"
SEND_METHOD = "    @objc func sendButtonPressed() {\n"
NEXT_METHOD = "    @objc func sendAsAvatarButtonPressed() {\n"
PREFERENCE = "WhitegramTextSettings.current.inAppVibrationEnabled"
SEND_BRANCH = """        if let presentationInterfaceState = self.presentationInterfaceState, presentationInterfaceState.interfaceState.mediaDraftState != nil {
            self.interfaceInteraction?.sendRecordedMedia(false, self.viewOnce)
            self.viewOnce = false
        } else {
            self.sendMessage()
        }
"""
INSTALLED_BRANCH = SEND_BRANCH.replace(
    "            self.sendMessage()\n",
    "            if WhitegramTextSettings.current.inAppVibrationEnabled {\n"
    "                self.hapticFeedback.impact(.medium)\n"
    "            }\n"
    "            self.sendMessage()\n",
)


def apply_feedback_patches(root: Path) -> dict[str, list[str]]:
    patches = SourcePatches(root)
    feature = "inAppVibration"
    source = patches.read(PANEL)
    if source.count(SEND_METHOD) != 1 or source.count(NEXT_METHOD) != 1:
        raise ValueError(f"{feature}: {PANEL}: missing or ambiguous send-button methods")
    start, end = source.index(SEND_METHOD), source.index(NEXT_METHOD)
    if end <= start:
        raise ValueError(f"{feature}: {PANEL}: unexpected send-button method order")
    method = source[start:end]
    if source.count(PREFERENCE) != method.count(INSTALLED_BRANCH):
        raise ValueError(f"{feature}: {PANEL}: partial or misplaced feedback hook")
    original = method.replace(INSTALLED_BRANCH, SEND_BRANCH)
    if original.count(SEND_BRANCH) != 1:
        raise ValueError(f"{feature}: {PANEL}: missing or ambiguous ordinary-send branch")
    error_return = "                self.hapticFeedback.error()\n                return\n"
    if error_return not in original[:original.index(SEND_BRANCH)]:
        raise ValueError(f"{feature}: {PANEL}: missing preceding overlength error return")
    patches.replace(feature, PANEL, original, original.replace(SEND_BRANCH, INSTALLED_BRANCH))
    return patches.write()
