"""Recovered outgoing formatting and display-only Unicode filtering."""

from source_patches import SourcePatches

TEXT_PROCESSING_RUNTIME_FILES = {
    "WhitegramTextSettings.swift": "submodules/TelegramCore/Sources/WhitegramTextSettings.swift",
    "WhitegramTextEntities.swift": "submodules/TelegramCore/Sources/WhitegramTextEntities.swift",
    "WhitegramComposerStrings.swift": "submodules/TelegramCore/Sources/WhitegramComposerStrings.swift",
    "WhitegramTextFormattingController.swift": "submodules/SettingsUI/Sources/WhitegramTextFormattingController.swift",
}
COMPOSER = "submodules/TelegramUI/Sources/ChatControllerNode.swift"
MEDIA = "submodules/LegacyMediaPickerUI/Sources/LegacyMediaPickers.swift"
TEXT = "submodules/TelegramUI/Components/Chat/ChatMessageTextBubbleContentNode/Sources/ChatMessageTextBubbleContentNode.swift"
TITLES = "submodules/LocalizedPeerData/Sources/PeerTitle.swift"
SNIPPETS = "submodules/ListMessageItem/Sources/ListMessageSnippetItemNode.swift"


def apply_text_processing_patches(root):
    patches = SourcePatches(root)
    anchor = "                            let entities: [MessageTextEntity]\n"
    patches.replace("autoFormatStyle", COMPOSER, anchor, anchor.replace("let entities", "var entities"))
    anchor = "                            if !entities.isEmpty {\n                                attributes.append(TextEntitiesMessageAttribute(entities: entities))\n"
    addition = "                            let whitegramOutgoingText = WhitegramTextEntities.outgoing(text: text.string, entities: entities, enabled: !sendWithoutFormatting)\n                            entities = whitegramOutgoingText.entities\n"
    patches.replace("autoFormatStyle", COMPOSER, anchor, addition + anchor)
    anchor = "messages.append(.message(text: text.string, attributes: attributes, inlineStickers: inlineStickers, mediaReference: mediaReference,"
    patches.replace("autoFormatStyle", COMPOSER, anchor, anchor.replace("text: text.string", "text: whitegramOutgoingText.text"))

    anchor = "let entities = generateTextEntities(text.string, enabledTypes: .all, currentEntities: generateChatInputTextEntities(text))"
    replacement = "let whitegramOutgoingText = WhitegramTextEntities.outgoing(text: text.string, entities: generateTextEntities(text.string, enabledTypes: .all, currentEntities: generateChatInputTextEntities(text)))\n"
    # Different caption branches have different indentation, so preserve each prefix.
    for indent, count in ((44, 1), (52, 1), (40, 1), (36, 2), (28, 1)):
        prefix = "\n" + " " * indent
        patches.replace("autoFormatStyle", MEDIA, prefix + anchor, prefix + replacement.rstrip("\n") + prefix + "let entities = whitegramOutgoingText.entities", count=count)
    patches.replace("autoFormatMixedScript", MEDIA, "text: text.string,\n", "text: whitegramOutgoingText.text,\n", count=6)
    patches.replace("autoFormatMixedScript", MEDIA, ".message(text: text.string,", ".message(text: whitegramOutgoingText.text,", count=6)

    start = "    func displayTitle(strings: PresentationStrings, displayOrder: PresentationPersonNameOrder) -> String {\n"
    end = "\n}\n\npublic extension EnginePeer.IndexName {"
    original = patches.read(TITLES)
    method = original[original.index(start):original.index(end)]
    for expression, count in (("\"\\(firstName) \\(lastName)\"", 1), ("\"\\(lastName) \\(firstName)\"", 1), ("firstName", 1), ("lastName", 1), ("group.title", 1), ("channel.title", 1), ("community.title", 1)):
        before = "return " + expression + "\n"
        after = "return WhitegramTextSettings.current.stripZalgo(" + expression + ")\n"
        if method.count(after) != count:
            if method.count(before) != count:
                raise ValueError("zalgoFilterEnabled: unexpected display-title return: " + expression)
            method = method.replace(before, after)
    patches.replace("zalgoFilterEnabled", TITLES, original[original.index(start):original.index(end)], method)

    anchor = "                var formattedDateUpdatePeriod: Int32?\n"
    addition = '''                if invoice == nil && story == nil && !isUnsupportedMedia && item.attributes.updatingMedia == nil {
                    let whitegramDisplayText = WhitegramTextEntities.display(text: rawText, entities: messageEntities)
                    rawText = whitegramDisplayText.text
                    messageEntities = whitegramDisplayText.entities
                }

'''
    patches.replace("zalgoFilterEnabled", TEXT, anchor, anchor + addition)
    anchor = "            let timestamp = Int32(CFAbsoluteTimeGetCurrent() + NSTimeIntervalSince1970)\n"
    addition = '''            let whitegramTextSettings = WhitegramTextSettings.current
            title = title.map { whitegramTextSettings.stripZalgo($0) }
            descriptionText = descriptionText.map { whitegramTextSettings.stripZalgo($0) }
            linkText = linkText.map { whitegramTextSettings.stripZalgo($0) }

'''
    patches.replace("zalgoFilterEnabled", SNIPPETS, anchor, addition + anchor)
    return patches.write()
