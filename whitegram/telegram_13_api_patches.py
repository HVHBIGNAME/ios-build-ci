"""Preserve Telegram 13 navigation and audio-session callback contracts."""

from pathlib import Path

from source_patches import SourcePatches


CHAT = "submodules/TelegramUI/Sources/Chat/ChatControllerLoadDisplayNode.swift"
AUDIO_PROTOCOL = "submodules/TelegramAudio/Sources/ManagedAudioSession.swift"
PLAYER_SESSION = "submodules/TelegramUI/Sources/WhitegramPlayerAudioSession.swift"


def apply_telegram_13_api_patches(root: Path) -> dict[str, list[str]]:
    patches = SourcePatches(root)
    prefix = "        historyNode.openNextChannelToRead = { [weak self] peer, threadData, location -> Bool in\n"
    if prefix in patches.read(CHAT):
        prefix += "            guard let strongSelf = self else {\n                return false\n            }\n"
        prefix += "            guard WhiteGramChatSettings.current.channelSwipeToNext else {\n"
        patches.replace(
            "channel-swipe-declined-navigation", CHAT,
            prefix + "                return\n            }",
            prefix + "                return false\n            }",
        )
    if "func getIsRecordingActive() -> Bool" in patches.read(AUDIO_PROTOCOL):
        anchor = "    func getIsHeadsetPluggedIn() -> Bool { return self.base.getIsHeadsetPluggedIn() }"
        patches.replace(
            "player-recording-session-status", PLAYER_SESSION, anchor,
            "    func getIsRecordingActive() -> Bool { return self.base.getIsRecordingActive() }\n" + anchor,
        )
    return patches.write()
