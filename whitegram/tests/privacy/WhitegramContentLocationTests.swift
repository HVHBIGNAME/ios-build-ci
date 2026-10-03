import Foundation
import XCTest
@testable import TelegramCore

final class WhitegramContentLocationTests: XCTestCase {
    private let keys = [WhitegramPreferences.storageKey, "WhitegramPrivacySettings.v1", "wg_fakeLat", "wg_fakeLon", "wg_fakeLocationEnabled", "wg_unrelatedLocationTest"]
    private var saved: [String: Any] = [:]

    override func setUp() {
        for key in keys {
            saved[key] = UserDefaults.standard.object(forKey: key)
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    override func tearDown() {
        for key in keys {
            UserDefaults.standard.removeObject(forKey: key)
            if let value = saved[key] { UserDefaults.standard.set(value, forKey: key) }
        }
    }

    func testOriginalZeroPairSentinelAndIndependentEnableFlag() {
        XCTAssertNil(WhitegramContentLocation.configured)
        XCTAssertTrue(WhitegramContentLocation.set(latitude: 0.0, longitude: 20.0))
        XCTAssertNotNil(WhitegramContentLocation.configured)
        XCTAssertNil(WhitegramContentLocation.effective)
        XCTAssertTrue(WhitegramContentSettings.set(true, for: "fakeLocationEnabled"))
        XCTAssertEqual(WhitegramContentLocation.effective?.longitude, 20.0)
        XCTAssertTrue(WhitegramContentLocation.set(latitude: 45.0, longitude: 0.0))
        XCTAssertEqual(WhitegramContentLocation.effective?.latitude, 45.0)
        XCTAssertTrue(WhitegramContentLocation.set(latitude: 0.0, longitude: 0.0))
        XCTAssertNil(WhitegramContentLocation.effective)
    }

    func testCanonicalCoordinatesTakePrecedenceOverOriginalMirrors() {
        UserDefaults.standard.set(35.0, forKey: "wg_fakeLat")
        UserDefaults.standard.set(139.0, forKey: "wg_fakeLon")
        XCTAssertEqual(WhitegramContentLocation.configured?.latitude, 35.0)
        XCTAssertTrue(WhitegramContentLocation.set(latitude: -30.0, longitude: 120.0))
        UserDefaults.standard.set(5.0, forKey: "wg_fakeLat")
        XCTAssertEqual(WhitegramContentLocation.configured?.latitude, -30.0)
        XCTAssertEqual(WhitegramContentLocation.configured?.longitude, 120.0)
    }

    func testInvalidCoordinatesNeverPersistOrBecomeABooleanCoordinate() {
        XCTAssertTrue(WhitegramContentLocation.set(latitude: 10.0, longitude: 20.0))
        for point in [(Double.nan, 2.0), (1.0, Double.infinity), (91.0, 2.0), (1.0, -181.0)] {
            XCTAssertFalse(WhitegramContentLocation.set(latitude: point.0, longitude: point.1))
        }
        XCTAssertEqual(WhitegramContentLocation.configured?.latitude, 10.0)
        XCTAssertTrue(WhitegramPreferences.set(true, for: "fakeLat"))
        XCTAssertNil(WhitegramContentLocation.configured)
        XCTAssertTrue(WhitegramPreferences.set("10", for: "fakeLat"))
        XCTAssertNil(WhitegramContentLocation.configured)
    }

    func testCoordinateUpdateIsOneObservableSnapshotAndPreservesOtherSettings() {
        XCTAssertTrue(WhitegramPreferences.set("retained", for: "unrelatedLocationTest"))
        var snapshots: [WhitegramContentLocation.Coordinate] = []
        let observer = NotificationCenter.default.addObserver(forName: WhitegramPreferences.updatedNotification, object: nil, queue: nil) { _ in
            if let coordinate = WhitegramContentLocation.configured { snapshots.append(coordinate) }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        XCTAssertTrue(WhitegramContentLocation.set(latitude: 12.25, longitude: -34.5))
        XCTAssertEqual(snapshots.count, 1)
        XCTAssertEqual(snapshots.first?.latitude, 12.25)
        XCTAssertEqual(snapshots.first?.longitude, -34.5)
        XCTAssertEqual(UserDefaults.standard.double(forKey: "wg_fakeLat"), 12.25)
        XCTAssertEqual(UserDefaults.standard.double(forKey: "wg_fakeLon"), -34.5)
        XCTAssertEqual(WhitegramPreferences.string("unrelatedLocationTest"), "retained")
    }
}
