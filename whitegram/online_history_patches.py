"""Capture accepted peer-presence updates without changing Telegram's merge rules."""

from source_patches import SourcePatches


PEERS = "submodules/TelegramCore/Sources/UpdatePeers.swift"
ONLINE_HISTORY_RUNTIME_FILES = {
    "WhitegramOnlineHistoryStore.swift": "submodules/TelegramCore/Sources/WhitegramOnlineHistoryStore.swift",
    "WhitegramOnlineHistoryCapture.swift": "submodules/TelegramCore/Sources/WhitegramOnlineHistoryCapture.swift",
    "WhitegramOnlineHistoryController.swift": "submodules/SettingsUI/Sources/WhitegramOnlineHistoryController.swift",
}


def apply_online_history_patches(root):
    patches = SourcePatches(root)
    for next_function, method, values in (
        ("updatePeerPresencesClean", "recordUsers", "users: peerPresences"),
        ("updatePeerPresenceLastActivities", "record", "statuses: peerPresences.mapValues { $0.status }"),
    ):
        anchor = f"    }})\n}}\n\nfunc {next_function}("
        hook = f"    WhitegramOnlineHistoryCapture.{method}(transaction: transaction, accountPeerId: accountPeerId, {values}, acceptedPeerIds: Set(parsedPresences.keys))\n"
        replacement = f"    }})\n{hook}}}\n\nfunc {next_function}("
        marker = f"WhitegramOnlineHistoryCapture.{method}("
        source = patches.read(PEERS)
        if marker in source and replacement not in source:
            raise ValueError("onlineHistoryEnabled: unrecognized or partial presence hook")
        patches.replace("onlineHistoryEnabled", PEERS, anchor, replacement)
        if patches.read(PEERS).count(marker) != 1:
            raise ValueError("onlineHistoryEnabled: expected one hook per presence input")
    return patches.write()
