import Foundation
import XCTest
@testable import TelegramCore

final class WhitegramTransferTests: XCTestCase {
    func testOriginalDownloadModeTableAndLegacyPrecedence() {
        for (mode, count) in [(1, 4), (2, 8), (3, 16)] {
            for legacy in [true, false] {
                let settings = WhitegramTransferSettings(values: ["downloadAccelMode": mode, "maxDownloadSpeed": legacy])
                XCTAssertEqual(settings.downloadParallelParts, count)
                XCTAssertTrue(settings.usesAcceleratedDownload)
            }
        }
        XCTAssertEqual(WhitegramTransferSettings(values: [:]).downloadParallelParts, 6)
        XCTAssertFalse(WhitegramTransferSettings(values: [:]).usesAcceleratedDownload)
        XCTAssertEqual(WhitegramTransferSettings(values: ["maxDownloadSpeed": true]).downloadParallelParts, 16)
        XCTAssertTrue(WhitegramTransferSettings(values: ["maxDownloadSpeed": true]).usesAcceleratedDownload)
    }

    func testUploadNativeOverrideAndBothAccelerationSwitches() {
        for send in [true, false] {
            for legacy in [true, false] {
                let settings = WhitegramTransferSettings(values: ["sendAccelerationEnabled": send, "maxDownloadSpeed": legacy])
                XCTAssertEqual(settings.uploadParallelParts(increaseParallelParts: true), 30)
                XCTAssertEqual(settings.uploadParallelParts(increaseParallelParts: false), send || legacy ? 16 : 3)
            }
        }
        // A download-mode selection alone does not alter upload concurrency.
        XCTAssertEqual(WhitegramTransferSettings(values: ["downloadAccelMode": 3]).uploadParallelParts(increaseParallelParts: false), 3)
    }

    func testMalformedSettingsCannotCreateUnboundedTransferWindows() {
        let invalidModes: [Any] = [true, false, "3", -1, 4, 2.5, Double.nan, Double.infinity, Double.greatestFiniteMagnitude, Int.max]
        for value in invalidModes {
            let settings = WhitegramTransferSettings(values: ["downloadAccelMode": value, "sendAccelerationEnabled": 1, "maxDownloadSpeed": "true"])
            XCTAssertEqual(settings.downloadMode, .telegram)
            XCTAssertEqual(settings.downloadParallelParts, 6)
            XCTAssertEqual(settings.uploadParallelParts(increaseParallelParts: false), 3)
        }
        let invalidWithLegacy = WhitegramTransferSettings(values: ["downloadAccelMode": -1, "maxDownloadSpeed": true])
        XCTAssertEqual(invalidWithLegacy.downloadParallelParts, 16)
    }

    func testLegacyReadAndCanonicalReset() throws {
        let suite = "whitegram-transfer-test-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(2, forKey: "wg_downloadAccelMode")
        defaults.set(true, forKey: "wg_sendAccelerationEnabled")
        defaults.set(true, forKey: "wg_maxDownloadSpeed")
        let legacy = WhitegramTransferSettings(values: [:], legacyDefaults: defaults)
        XCTAssertEqual(legacy.downloadParallelParts, 8)
        XCTAssertEqual(legacy.uploadParallelParts(increaseParallelParts: false), 16)
        let reset = WhitegramTransferSettings(values: WhitegramTransferSettings.resetValues, legacyDefaults: defaults)
        XCTAssertEqual(reset.downloadParallelParts, 6)
        XCTAssertEqual(reset.uploadParallelParts(increaseParallelParts: false), 3)
        XCTAssertFalse(reset.usesAcceleratedDownload)
    }
}
