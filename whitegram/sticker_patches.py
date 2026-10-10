"""Restore the original finite local limits behind the unlimited-sticker controls."""

from source_patches import SourcePatches


CORE = "submodules/TelegramCore/Sources/"
STICKER_RUNTIME_FILES = {
    "WhitegramStickerSettings.swift": CORE + "WhitegramStickerSettings.swift",
}
RECENT_TARGETS = {
    CORE + "State/ApplyUpdateMessage.swift": 2,
    CORE + "State/AccountStateManagementUtils.swift": 1,
    CORE + "State/SynchronizeRecentlyUsedMediaOperations.swift": 1,
}
SAVED = CORE + "State/SynchronizeSavedStickersOperation.swift"
TOGGLE = CORE + "TelegramEngine/Stickers/SavedStickers.swift"


def apply_sticker_patches(root):
    patches = SourcePatches(root)
    for path, count in RECENT_TARGETS.items():
        anchor = "collectionId: Namespaces.OrderedItemList.CloudRecentStickers, item: OrderedItemListEntry(id: RecentMediaItemId("
        suffix = ").rawValue, contents: entry), removeTailIfCountExceeds: 20)"
        file = "fileReference.media.fileId" if "SynchronizeRecentlyUsed" in path else "file.fileId"
        before = anchor + file + suffix
        patches.replace("unlimitedRecentStickers", path, before,
                        before.replace("removeTailIfCountExceeds: 20", "removeTailIfCountExceeds: WhitegramStickerSettings.current.recentLimit"), count=count)
    before = "collectionId: Namespaces.OrderedItemList.CloudSavedStickers, item: OrderedItemListEntry(id: RecentMediaItemId(file.fileId).rawValue, contents: entry), removeTailIfCountExceeds: limit)"
    patches.replace("unlimitedFavoriteStickers", SAVED, before,
                    before.replace("removeTailIfCountExceeds: limit", "removeTailIfCountExceeds: WhitegramStickerSettings.current.favoriteLimit(default: limit)"))
    # Preserve the caller's premium/default limit in all three asynchronous paths.
    for file, representations in (("stickerItem.file._parse()", "stringRepresentations"), ("file", "stickerStringRepresentations"), ("file", "[]")):
        before = f"addSavedSticker(transaction: transaction, file: {file}, stringRepresentations: {representations})"
        patches.replace("unlimitedFavoriteStickers", SAVED, before, before[:-1] + ", limit: limit)")
    before = "            if isPremium && items.count >= premiumLimitsConfiguration.maxFavedStickerCount {"
    patches.replace("unlimitedFavoriteStickers", TOGGLE, before,
                    "            if WhitegramStickerSettings.current.unlimitedFavorites {\n                result = .generic\n            } else if isPremium && items.count >= premiumLimitsConfiguration.maxFavedStickerCount {")
    before = "limit: Int(isPremium ? premiumLimitsConfiguration.maxFavedStickerCount : limitsConfiguration.maxFavedStickerCount))"
    patches.replace("unlimitedFavoriteStickers", TOGGLE, before,
                    "limit: WhitegramStickerSettings.current.favoriteLimit(default: Int(isPremium ? premiumLimitsConfiguration.maxFavedStickerCount : limitsConfiguration.maxFavedStickerCount)))")
    return patches.write()
