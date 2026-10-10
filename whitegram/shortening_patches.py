"""Connect the recovered local shorten/expand action without changing message text."""

from source_patches import SourcePatches

MENU = "submodules/TelegramUI/Sources/ChatInterfaceStateContextMenus.swift"
TEXT = "submodules/TelegramUI/Components/Chat/ChatMessageTextBubbleContentNode/Sources/ChatMessageTextBubbleContentNode.swift"

ACTION = '''        if !isAction && !isEmbeddedMode {
            let shortened = message.whitegramHistoryAttribute?.isShortened == true
            if shortened || (WhitegramPreferences.bool("messageShortenEnabled", default: UserDefaults.standard.bool(forKey: "wg_messageShortenEnabled")) && WhitegramMessageShortening.canShorten(message.text)) {
                let title = WhitegramLocalization.string(shortened ? "m.expandMessage" : "m.shorten", baseLanguage: chatPresentationInterfaceState.strings.baseLanguageCode)
                actions.append(.action(ContextMenuActionItem(text: title, icon: { theme in
                    return generateTintedImage(image: UIImage(systemName: shortened ? "arrow.up.and.down.text.horizontal" : "text.alignleft"), color: theme.actionSheet.primaryTextColor)
                }, action: { c, _ in
                    c?.dismiss(completion: {
                        let _ = WhitegramHistoryRuntime.setShortened(postbox: context.account.postbox, id: message.id, shortened: !shortened).start()
                    })
                })))
            }
        }

'''

RENDER = '''                var whitegramCanShorten = !item.presentationData.isPreview && item.attributes.updatingMedia == nil && invoice == nil && story == nil && !isUnsupportedMedia
                if let subject = item.associatedData.subject, case .messageOptions = subject { whitegramCanShorten = false }
                if whitegramCanShorten, item.message.whitegramHistoryAttribute?.isShortened == true, rawText == item.message.text {
                    let prefix = WhitegramMessageShortening.prefix(rawText)
                    messageEntities = messageEntities?.compactMap { entity in
                        guard let range = WhitegramMessageShortening.clippedRange(entity.range, prefixUTF16Count: prefix.utf16.count),
                              WhitegramTranslationTextRules.validRange(range, in: prefix) else { return nil }
                        return MessageTextEntity(range: range, type: entity.type)
                    }
                    rawText = prefix + "…"
                }

'''


def apply_shortening_patches(root):
    patches = SourcePatches(root)
    anchor = "        var downloadableMediaResourceInfos: [String] = []\n"
    patches.replace("messageShortenEnabled", MENU, anchor, ACTION + anchor)
    anchor = "                var formattedDateUpdatePeriod: Int32?\n"
    patches.replace("messageShortenEnabled", TEXT, anchor, RENDER + anchor)
    return patches.write()
