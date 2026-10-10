import Foundation

// Compile with the production AppearancePolicy and LocalStars sources on macOS.
enum WhitegramPreferences {
    static func values() -> [String: Any] { return [:] }
}

public struct StarsAmount: Equatable {
    public let value: Int64
    public let nanos: Int32
    public init(value: Int64, nanos: Int32) { self.value = value; self.nanos = nanos }
}

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    precondition(condition(), message)
}

let defaults = WhitegramAppearancePolicy(values: [:])
let stickerDefaults = WhitegramStickerSettings(values: [:])
check(stickerDefaults.recentLimit == 20, "Disabled recent override preserves Telegram's limit")
check(stickerDefaults.favoriteLimit(default: 5) == 5 && stickerDefaults.favoriteLimit(default: 10) == 10, "Disabled favorite override preserves free and premium limits")
let unlimitedStickers = WhitegramStickerSettings(values: ["unlimitedRecentStickers": true, "unlimitedFavoriteStickers": true])
check(unlimitedStickers.recentLimit == 999, "Original recent limit is 999, not unbounded")
check(unlimitedStickers.favoriteLimit(default: 5) == 9999, "Original favorite limit is 9999")
check(!WhitegramStickerSettings(values: ["unlimitedRecentStickers": 1]).unlimitedRecent, "A numeric value cannot enable sticker retention")
check(defaults.stickerScale == 1.0, "Unset stickers use original size")
check(defaults.tabWidthPercent == 100.0, "Tab width stores percent, not factor")
check(defaults.tabHeightPercent == 100.0, "Tab height stores percent, not factor")
check(WhitegramAppearancePolicy(values: ["stickerSizeScale": 0]).stickerScale == 1.0, "Original zero means default")
check(WhitegramAppearancePolicy(values: ["stickerSizeScale": 2.0]).stickerScale == 2.0, "Original slider supports 200 percent")
check(WhitegramAppearancePolicy(values: ["stickerSizeScale": 100]).stickerScale == 2.0, "Untrusted oversized scale is bounded")
check(WhitegramAppearancePolicy(values: ["stickerSizeScale": -1]).stickerScale == 0.1, "Negative scale cannot invert geometry")
check(WhitegramAppearancePolicy(values: ["stickerSizeScale": Double.nan]).stickerScale == 1.0, "NaN cannot reach layout")
check(WhitegramAppearancePolicy(values: ["tabBarWidthScale": 0]).tabWidthPercent == 100.0, "Zero tab width means default")
check(WhitegramAppearancePolicy(values: ["tabBarWidthScale": 75]).tabWidthPercent == 75.0, "Percent is retained")
for (value, expected) in [(-1.0, 100.0), (0.0, 100.0), (1.0, 50.0), (50.0, 50.0), (75.0, 75.0), (100.0, 100.0), (150.0, 150.0), (900.0, 150.0)] {
    check(WhitegramAppearancePolicy(values: ["tabBarScale": value]).tabHeightPercent == expected, "Original tab-height rendering clamp")
    check(WhitegramAppearancePolicy(values: ["tabBarWidthScale": value]).tabWidthPercent == expected, "Original tab-width rendering clamp")
}
check(WhitegramAppearancePolicy.parseStickerPercent("10") == 0.1, "Original sticker lower input bound")
check(WhitegramAppearancePolicy.parseStickerPercent("200") == 2.0, "Original sticker upper input bound")
for invalid in ["0", "9", "201", "10.5", "NaN", "inf", ""] {
    check(WhitegramAppearancePolicy.parseStickerPercent(invalid) == nil, "Invalid sticker input")
}
check(WhitegramAppearancePolicy.parseTabHeightPercent("50") == 50.0, "Original height input lower bound")
check(WhitegramAppearancePolicy.parseTabHeightPercent("75.5") == 75.5, "Original height input accepts fractional percent")
check(WhitegramAppearancePolicy.parseTabHeightPercent("100") == 100.0, "Original height custom input upper bound")
for invalid in ["49.9", "100.1", "150", "NaN", "inf", ""] {
    check(WhitegramAppearancePolicy.parseTabHeightPercent(invalid) == nil, "Height custom input differs from slider range")
}
check(!WhitegramAppearancePolicy(values: ["hideReactions": 1]).isEnabled("hideReactions"), "Numeric one is not a Boolean")
check(WhitegramAppearancePolicy(values: ["hideReactions": true]).isEnabled("hideReactions"), "Boolean switch is honored")
check(WhitegramAppearancePolicy(values: [:]) != WhitegramAppearancePolicy(values: ["lightChatUI": true]), "Blur replacement invalidates open-chat presentation")
check(WhitegramAppearancePolicy.bubbleFillOpacity(transparent: false, semiTransparent: true) == 0.7, "Original semi-transparent alpha")
check(WhitegramAppearancePolicy.bubbleFillOpacity(transparent: true, semiTransparent: true) == 0.0, "Transparent fill has stable conflict precedence")
check(WhitegramAppearancePolicy.bubbleFillOpacity(transparent: false, semiTransparent: false) == 1.0, "Default fill is opaque")
let graphemes = "👨‍👩‍👧‍👦e\u{301}🇺🇦"
check(WhitegramAppearancePolicy.inputCounter(enabled: true, text: graphemes, limit: nil).text == "3", "Count graphemes, not UTF-16 units")
check(WhitegramAppearancePolicy.inputCounter(enabled: false, text: graphemes, limit: nil).text.isEmpty, "Disabled composer has no new count")
check(WhitegramAppearancePolicy.inputCounter(enabled: true, text: "abc", limit: 8).text == "3 / 8", "Five remaining characters do not suppress the local counter")
check(WhitegramAppearancePolicy.inputCounter(enabled: true, text: "abcd", limit: 8).text == "4", "Native remaining-count warning wins below five")
check(WhitegramAppearancePolicy.inputCounter(enabled: false, text: "abcde", limit: 4).isOverLimit, "Native limit warning works with the preference off")
check(WhitegramAppearancePolicy.inputCounter(enabled: true, text: String(repeating: "a", count: 2000), limit: 1).text == "-999", "Preserve Telegram's remaining-count display cap")
check(WhitegramAppearancePolicy.messageStatus(enabled: true, dateText: "12:34", text: graphemes, russian: false) == "3 chars · 12:34", "Status suffix preserves the supplied timestamp")
check(WhitegramAppearancePolicy.messageStatus(enabled: false, dateText: "12:34", text: graphemes, russian: true) == "12:34", "Disabled count leaves status text intact")

let glassDefaults = WhitegramGlassSettings(values: [:])
check(glassDefaults.replacement == .system && !glassDefaults.hasBubbleSurface, "Original glass switches default off")
for toggle in WhitegramGlassSettings.Toggle.allCases {
    check(!WhitegramGlassSettings(values: [toggle.rawValue: 1]).isSelected(toggle), "Numeric flags do not enable a material")
    check(!WhitegramGlassSettings(values: [toggle.rawValue: "true"]).isSelected(toggle), "String flags do not enable a material")
    check(WhitegramGlassSettings(values: [toggle.rawValue: true]).isSelected(toggle), "Boolean material selection is retained")
}
let glass = WhitegramGlassSettings(values: ["glassMessageBubbles": true, "liquidGlassBubbles": true])
check(glass.material(for: .bubbles) == .glass, "Conflicting imported bubble modes have stable precedence")
check(WhitegramGlassSettings(values: ["liquidGlassBubbles": true]).material(for: .bubbles) == .blur, "Blur bubbles are distinct from Liquid Glass")
let classic = WhitegramGlassSettings(values: ["classicInterface": true, "glassMessageBubbles": true, "liquidGlassSettings": true, "fakeLiquidGlass": true])
check(classic.isSelected(.glassMessageBubbles) && !classic.hasBubbleSurface, "Classic suppression preserves saved selection")
check(classic.material(for: .settings) == nil && classic.replacement == .telegram, "Classic suppresses opt-in surfaces without conflating global materials")
let mixed = WhitegramGlassSettings(values: ["fakeLiquidGlass": true, "colorInsteadOfGlass": true, "lightChatUI": true])
check(mixed.replacement == .color, "Opaque replacement wins conflicting imports")
for toggle in [WhitegramGlassSettings.Toggle.fakeLiquidGlass, .colorInsteadOfGlass, .lightChatUI] {
    let changes = WhitegramGlassSettings.changes(for: toggle, enabled: true)
    check(changes.count == 3 && (changes[toggle.rawValue] as? Bool) == true, "A replacement atomically disables its alternatives")
    check(changes.values.compactMap { $0 as? Bool }.filter { $0 }.count == 1, "Only one replacement survives a user selection")
    check(WhitegramGlassSettings.changes(for: toggle, enabled: false).count == 1, "Disabling a replacement leaves other saved fields untouched")
}
let bubbleChanges = WhitegramGlassSettings.changes(for: .glassMessageBubbles, enabled: true)
check((bubbleChanges["transparentMessages"] as? Bool) == false && (bubbleChanges["semiTransparentBubbles"] as? Bool) == false, "Choosing glass clears incompatible fills atomically")
check(bubbleChanges["messageBorderEnabled"] == nil, "Borders remain independently selectable")
check(WhitegramGlassSettings.resetValues["classicInterface"] == nil, "Glass reset never rewrites classic layout selection")

let suite = "WhitegramAppearanceTests." + UUID().uuidString
let legacy = UserDefaults(suiteName: suite)!
defer { legacy.removePersistentDomain(forName: suite) }
legacy.set(true, forKey: "wg_unlimitedRecentStickers")
check(WhitegramStickerSettings(values: [:], legacyDefaults: legacy).recentLimit == 999, "Original sticker preference is read")
check(WhitegramStickerSettings(values: ["unlimitedRecentStickers": false], legacyDefaults: legacy).recentLimit == 20, "Explicit false overrides the legacy sticker preference")
legacy.set(true, forKey: "wg_hideReactions")
legacy.set(150.0, forKey: "wg_tabBarWidthScale")
legacy.set(true, forKey: "wg_liquidGlassProfile")
check(WhitegramGlassSettings(values: [:], defaults: legacy).material(for: .profile) == .glass, "Original primitive glass settings migrate")
check(WhitegramGlassSettings(values: ["liquidGlassProfile": false], defaults: legacy).material(for: .profile) == nil, "Saved false takes precedence over a stale primitive")
check(WhitegramAppearancePolicy(values: [:], legacyDefaults: legacy).isEnabled("hideReactions"), "Original primitive is read")
check(!WhitegramAppearancePolicy(values: ["hideReactions": false], legacyDefaults: legacy).isEnabled("hideReactions"), "Explicit saved false wins")
check(WhitegramAppearancePolicy(values: [:], legacyDefaults: legacy).tabWidthPercent == 150.0, "Original percent mirror is read")

let actual = StarsAmount(value: 17, nanos: 250000000)
let off = WhitegramLocalStars(values: [:])
check(off.count == 9999, "Original local Stars default")
check(off.displayBalance(actual) == actual, "Disabled preserves fractional actual balance")
let on = WhitegramLocalStars(values: ["localStarsEnabled": true, "localStarsCount": Int64.max])
check(on.displayBalance(actual) == StarsAmount(value: Int64.max, nanos: 0), "Display avoids Double rounding of Int64")
check(actual == StarsAmount(value: 17, nanos: 250000000), "Input balance is immutable")
check(WhitegramLocalStars(values: ["localStarsCount": 0]).count == 9999, "Zero means original default")
check(WhitegramLocalStars(values: ["localStarsCount": true]).count == 9999, "Boolean count is invalid")
check(WhitegramLocalStars.parseCount(" 9999999 ") == 9_999_999, "Original custom input upper bound")
check(WhitegramLocalStars.parseCount("1") == 1, "Original custom input lower bound")
check(WhitegramLocalStars.parseCount("+1") == 1, "Original integer parser accepts a positive sign")
check(WhitegramLocalStars.sliderRange == 1 ... 9999, "Original slider has a smaller range than custom input")
check(WhitegramLocalStars(values: ["localStarsCount": NSNumber(value: 12500.0)]).count == 12500, "Integral JSON numbers remain valid")
check(WhitegramLocalStars(values: ["localStarsCount": 12.5]).count == 9999, "Fractional local balances are invalid")
for invalid in ["", "0", "-5", "1.5", "1e6", "10000000", "9223372036854775807", "9223372036854775808", "１２"] {
    check(WhitegramLocalStars.parseCount(invalid) == nil, "Reject invalid count: " + invalid)
}
let originalFont = ["fileName": "Example.ttf", "psName": "Example-Regular"]
check(WhitegramFontHistory.name(in: originalFont) == "Example-Regular", "Recover original font history schema")
legacy.set(try! JSONSerialization.data(withJSONObject: [originalFont]), forKey: "wg_customFontHistory")
check(WhitegramFontHistory.read(values: [:], defaults: legacy) == [originalFont], "Read original JSON Data history")
check(WhitegramFontHistory.read(values: ["fontHistory": [[String: String]]()], defaults: legacy).isEmpty, "Explicit empty library does not resurrect deleted original entries")
for invalid in ["../font.ttf", "C:\\font.ttf", "/font.ttf", "a/b.otf", "font.ttf\0", "font.zip"] {
    check(!WhitegramFontHistory.isFontFileName(invalid), "Reject unsafe font filename")
}

let family = try! WhitegramFontArchivePlan.fonts(in: [
    .init(path: "Family/", size: 0),
    .init(path: "Family/Regular.ttf", size: 4096),
    .init(path: "Family/Bold.otf", size: 4096),
    .init(path: "__MACOSX/._Regular.ttf", size: 8),
    .init(path: "README.txt", size: 128)
])
check(family.map { $0.path } == ["Family/Bold.otf", "Family/Regular.ttf"], "Import all family faces, ignoring resource forks and unrelated files")
for entries: [WhitegramFontArchivePlan.Entry] in [
    [.init(path: "../outside.ttf", size: 1)],
    [.init(path: "/absolute.ttf", size: 1)],
    [.init(path: "Family/a.ttf", size: 1), .init(path: "family/A.TTF", size: 2)],
    [.init(path: "empty.ttf", size: 0)],
    [.init(path: "huge.otf", size: UInt64.max)],
    [.init(path: "README.txt", size: 128)]
] {
    do { _ = try WhitegramFontArchivePlan.fonts(in: entries); preconditionFailure("Invalid font archive accepted") }
    catch is WhitegramFontArchiveError {}
    catch { preconditionFailure("Unexpected font error: \(error)") }
}

func rejectsArchive(_ entries: [WhitegramIconPackArchive.Entry]) {
    do { _ = try WhitegramIconPackArchive.plan(entries: entries); preconditionFailure("Unsafe archive accepted") }
    catch is WhitegramIconPackError {}
    catch { preconditionFailure("Unexpected error: \(error)") }
}
let archive = try! WhitegramIconPackArchive.plan(entries: [
    .init(path: "Example/manifest.json", size: 2),
    .init(path: "Example/icons/Chat/Copy.svg", size: 40),
    .init(path: "Example/icons/Star.tgs", size: 50),
    .init(path: "Example/README.txt", size: 20)
])
check(archive.prefix == "Example/", "One wrapper directory supported")
check(archive.files.count == 3 && archive.iconCount == 2, "Extract only manifest/icons; count animations")
rejectsArchive([.init(path: "manifest.json", size: 2), .init(path: "../escape.png", size: 4)])
rejectsArchive([.init(path: "manifest.json", size: 2), .init(path: "icons/a.png", size: 4), .init(path: "icons/A.png", size: 4)])
rejectsArchive([.init(path: "manifest.json", size: 2), .init(path: "icons/a.svg", size: UInt64.max)])
rejectsArchive([.init(path: "manifest.json", size: 2), .init(path: "other/manifest.json", size: 2), .init(path: "icons/a.svg", size: 4)])
rejectsArchive([.init(path: "manifest.json", size: 2)])
let manifest = try! WhitegramIconPackManifest(data: Data("{}".utf8), id: "example", fallbackName: "Example", iconCount: 2)
check(manifest.monochrome && manifest.iconScale == 1 && manifest.version == "1.0", "Recovered manifest defaults")
check(manifest.name == "Example" && manifest.id == "example", "Filename-derived identity")
for scale in [0.05, 4.0, -1.0, 100.0] {
    let data = try! JSONSerialization.data(withJSONObject: ["iconScale": scale])
    let value = try! WhitegramIconPackManifest(data: data, id: "p", fallbackName: "p", iconCount: 1)
    check(value.iconScale == 1, "Out-of-range scale uses the original default")
}
let colored = try! WhitegramIconPackManifest(data: Data("{\"monochrome\":false,\"iconScale\":2,\"description\":\"Example\"}".utf8), id: "p", fallbackName: "p", iconCount: 1)
check(!colored.monochrome && colored.iconScale == 2 && colored.packDescription == "Example", "Original manifest field names")
check(WhitegramIconPackArchive.identifier(for: "Example Pack") == "example-pack", "Original filename normalization")
print("Appearance, glass, Stars, font history and icon archive tests passed")
