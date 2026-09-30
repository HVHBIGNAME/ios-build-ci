import Foundation
import XCTest
@testable import TelegramCore

enum SettingsArchiveFixture {
    static func data(_ settings: [String: Any], version: Any = Int64(1), createdAt: Any = Int64(1700000000)) throws -> Data {
        return try JSONSerialization.data(withJSONObject: ["format": WhitegramSettingsArchive.format, "version": version, "createdAt": createdAt, "settings": settings])
    }

    static func archive(_ settings: [String: Any]) throws -> WhitegramSettingsArchive {
        return try WhitegramSettingsArchive(data: data(settings))
    }

    static func raw(_ settings: String) -> Data {
        return Data(("{\"format\":\"whitegram.settings.port\",\"version\":1,\"createdAt\":1700000000,\"settings\":" + settings + "}").utf8)
    }
}

final class WhitegramSettingsArchiveTests: XCTestCase {
    func testRoundTripRetainsTypesUnicodeAndExactInt64() throws {
        let archive = try SettingsArchiveFixture.archive([
            "ghostModeEnabled": true, "disableReadReceipts": false, "voiceChangerPitch": 1.5,
            "localStarsCount": Int64.max, "customFontName": "Шрифт-Regular", "messageBorderColorHex": "aAbBcc",
            "musicEqualizerBands": [-3.5, 0.0, 2.25], "public.other.translationService": "telegram"
        ])
        let decoded = try WhitegramSettingsArchive(data: archive.encoded())
        XCTAssertEqual(decoded.keys, archive.keys)
        XCTAssertEqual((decoded.values["localStarsCount"] as? NSNumber)?.int64Value, Int64.max)
        XCTAssertEqual(decoded.values["ghostModeEnabled"] as? Bool, true)
        XCTAssertEqual(decoded.values["disableReadReceipts"] as? Bool, false)
        XCTAssertEqual(decoded.values["voiceChangerPitch"] as? Double, 1.5)
        XCTAssertEqual(decoded.values["customFontName"] as? String, "Шрифт-Regular")
        XCTAssertEqual(decoded.values["messageBorderColorHex"] as? String, "#AABBCC")
        XCTAssertEqual(decoded.values["musicEqualizerBands"] as? [Double], [-3.5, 0, 2.25])
        XCTAssertEqual(decoded.createdAt, 1700000000)
    }

    func testRecognizedAliasesMigrateButAmbiguousAliasesFail() throws {
        let archive = try SettingsArchiveFixture.archive(["wg_ghostModeEnabled": true, "saveDeletedMessages": true, "wg_profileReactionsEnabled": false])
        XCTAssertEqual(archive.keys, ["ghostModeEnabled", "showDeletedMessages", "whitegramProfileReactionsEnabled"])
        XCTAssertEqual(Set(archive.migratedKeys), Set(archive.keys))
        XCTAssertThrowsError(try SettingsArchiveFixture.archive(["ghostModeEnabled": true, "wg_ghostModeEnabled": true]))
        XCTAssertThrowsError(try SettingsArchiveFixture.archive(["showDeletedMessages": true, "saveDeletedMessages": false]))
    }

    func testDuplicateKeysIncludingEscapedSpellingsFail() {
        for settings in [
            #"{"ghostModeEnabled":true,"ghostModeEnabled":false}"#,
            #"{"ghostModeEnabled":true,"ghost\u004dodeEnabled":false}"#
        ] {
            XCTAssertThrowsError(try WhitegramSettingsArchive(data: SettingsArchiveFixture.raw(settings))) { error in
                guard let error = error as? WhitegramSettingsArchiveError, case .duplicateKey = error else { return XCTFail("Expected duplicate-key rejection") }
            }
        }
        let duplicateEnvelope = #"{"format":"whitegram.settings.port","version":1,"version":1,"createdAt":0,"settings":{"ghostModeEnabled":true}}"#
        XCTAssertThrowsError(try WhitegramSettingsArchive(data: Data(duplicateEnvelope.utf8)))
    }

    func testMalformedEnvelopeAndUnsupportedVersionsFail() throws {
        for data in [
            Data(), Data("[]".utf8), Data("{}".utf8), Data("{bad".utf8),
            SettingsArchiveFixture.raw(#"{"ghostModeEnabled":true,}"#),
            SettingsArchiveFixture.raw(#"{"ghostModeEnabled":true} trailing"#),
            try SettingsArchiveFixture.data(["ghostModeEnabled": true], version: true),
            try SettingsArchiveFixture.data(["ghostModeEnabled": true], version: 1.5),
            try SettingsArchiveFixture.data(["ghostModeEnabled": true], version: 2),
            try SettingsArchiveFixture.data(["ghostModeEnabled": true], createdAt: false),
            try SettingsArchiveFixture.data(["ghostModeEnabled": true], createdAt: -1),
            try SettingsArchiveFixture.data(["ghostModeEnabled": true], createdAt: 1.25)
        ] { XCTAssertThrowsError(try WhitegramSettingsArchive(data: data)) }
        XCTAssertThrowsError(try SettingsArchiveFixture.archive([:]))
        XCTAssertThrowsError(try WhitegramSettingsArchive(data: Data(#"{"wg_ghostModeEnabled":true}"#.utf8)))
    }

    func testWrongTypesNullsRangesAndOverflowFailWithoutCoercion() throws {
        let invalid: [(String, Any)] = [
            ("ghostModeEnabled", 1), ("ghostModeEnabled", "true"), ("ghostModeEnabled", NSNull()),
            ("voiceChangerPitch", true), ("voiceChangerPitch", "1.5"), ("voiceChangerPitch", 12.1),
            ("videoMessageCamera", 1.5), ("videoMessageCamera", 3), ("localStarsCount", true),
            ("localStarsCount", -1), ("localStarsCount", UInt64.max), ("localStarsCount", 1.5),
            ("fakeLat", 91), ("photoCompressionQuality", 1.01), ("aiProvider", "unknown"),
            ("musicEqualizerBands", [true]), ("musicEqualizerBands", []), ("musicEqualizerBands", [25]),
            ("customFontName", "Font\nName"), ("customFontName", String(repeating: "a", count: 257)),
            ("messageBorderColorHex", "#zzzzzz"), ("public.other.translationService", "apple")
        ]
        for (key, value) in invalid { XCTAssertThrowsError(try SettingsArchiveFixture.archive([key: value]), key) }
        for number in [Double.nan, Double.infinity, -Double.infinity] {
            XCTAssertThrowsError(try WhitegramSettingsArchiveRule.number(-12...12).validate(number, key: "voiceChangerPitch"))
        }
        XCTAssertThrowsError(try WhitegramSettingsArchive(data: SettingsArchiveFixture.raw(#"{"voiceChangerPitch":1e999}"#)))
    }

    func testByteDepthAndContainerLimits() throws {
        XCTAssertThrowsError(try WhitegramSettingsArchive(data: Data(repeating: 32, count: WhitegramSettingsArchive.maximumBytes + 1)))
        XCTAssertThrowsError(try WhitegramSettingsArchive(data: SettingsArchiveFixture.raw(#"{"ghostModeEnabled":[[[[[true]]]]]}"#)))
        let many = Dictionary(uniqueKeysWithValues: (0..<385).map { ("unknown\($0)", true) })
        XCTAssertThrowsError(try SettingsArchiveFixture.archive(many))
        XCTAssertThrowsError(try SettingsArchiveFixture.archive(["musicEqualizerBands": Array(repeating: 0, count: 33)]))
    }

    func testSecretAndRuntimeKeysAreRejectedEvenWithPrimitivePrefix() throws {
        let prohibited = [
            "geminiApiKey", "groqApiKey", "virusTotalApiKey", "voiceChangerApiKey", "wg_geminiApiKey",
            "pluginRuntime.permissions.1.plugin", "wg_pluginRuntime.permissions.1.plugin", "plugins_meta_v1",
            "apiSessionToken_1", "authKey", "session", "activeWhitegramAccountId", "fontHistory",
            "customFontPath", "videoBackgroundPath", "profileQuoteText", "public.contextMenu.authKey", "unrelated"
        ]
        for key in prohibited {
            XCTAssertNil(WhitegramSettingsArchiveSchema.canonicalKey(key), key)
            XCTAssertThrowsError(try SettingsArchiveFixture.archive([key: "DO-NOT-EXPORT", "ghostModeEnabled": true])) { error in
                XCTAssertFalse(error.localizedDescription.contains("DO-NOT-EXPORT"))
            }
        }
    }

    func testExportAllowlistNeverSerializesCredentialsOrNestedRuntimeState() throws {
        let result = try WhitegramSettingsArchive.export(values: [
            "ghostModeEnabled": true, "voiceChangerPitch": "bad", "geminiApiKey": ["token": "secret-marker"],
            "wg_groqApiKey": "secret-marker", "virusTotalApiKey": "secret-marker", "voiceChangerApiKey": "secret-marker",
            "pluginRuntime.permissions.1.plugin": ["messages": true], "authKey": "secret-marker",
            "fontHistory": [["name": "secret-marker", "path": "/private/secret-marker"]]
        ], date: Date(timeIntervalSince1970: 1700000000))
        XCTAssertEqual(result.archive.keys, ["ghostModeEnabled"])
        XCTAssertEqual(result.omittedInvalidKeys, ["voiceChangerPitch"])
        let text = String(decoding: try result.archive.encoded(), as: UTF8.self)
        XCTAssertFalse(text.contains("secret-marker"))
        XCTAssertFalse(text.contains("ApiKey"))
        XCTAssertFalse(text.contains("permissions"))
    }

    func testContradictoryDoubleTapSettingsFail() throws {
        XCTAssertThrowsError(try SettingsArchiveFixture.archive(["doubleTapEditEnabled": true, "public.chat.personalChatDoubleTapAction": "reply"]))
        XCTAssertThrowsError(try SettingsArchiveFixture.archive(["doubleTapEditEnabled": false, "public.chat.personalChatDoubleTapAction": "edit"]))
        XCTAssertNoThrow(try SettingsArchiveFixture.archive(["doubleTapEditEnabled": false, "public.chat.personalChatDoubleTapAction": "reply"]))
    }
}
