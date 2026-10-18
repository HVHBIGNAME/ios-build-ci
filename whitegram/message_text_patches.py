"""Shared media eligibility for message-text consumers after the Telegram 13 move."""


def ensure_unsupported_media_flag(patches, path, feature):
    value = patches.read(path)
    if "var isUnsupportedMedia =" in value or "let isUnsupportedMedia =" in value:
        return
    anchor = "                var rawText: String\n"
    patches.replace(feature, path, anchor,
                    "                let isUnsupportedMedia = item.message.media.contains { $0 is TelegramMediaUnsupported }\n" + anchor)
