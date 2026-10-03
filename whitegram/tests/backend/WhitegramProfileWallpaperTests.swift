import Foundation
import XCTest
@testable import WhitegramBackendHost

final class WhitegramProfileWallpaperTests: XCTestCase {
    func testOriginalWallpaperPathAndPublicationPreferencesAreAccountScoped() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WhitegramWallpaperTest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "WhitegramWallpaperTest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = try WhitegramProfilePhotoWallStore(documents: root, defaults: defaults)
        let jpeg = Data([255, 216, 255, 224, 1, 2, 3])
        XCTAssertNil(try store.load(userId: 42))
        try store.save(jpeg, userId: 42)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("WallpapersProfile/my_wall_42.jpg")), jpeg)
        XCTAssertEqual(try store.load(userId: 42), jpeg)
        XCTAssertNil(try store.load(userId: 43))
        XCTAssertNil(store.savedPublicationPreference(userId: 42))
        try store.confirmedPublication(true, userId: 42)
        XCTAssertEqual(store.savedPublicationPreference(userId: 42), true)
        XCTAssertNil(store.savedPublicationPreference(userId: 43))
        XCTAssertThrowsError(try store.save(Data([0, 1, 2]), userId: 42))
        XCTAssertEqual(try store.load(userId: 42), jpeg)
        try store.removeLocal(userId: 42)
        XCTAssertNil(try store.load(userId: 42))
        // Deleting a local file alone must not claim that a remote wallpaper was removed.
        XCTAssertEqual(store.savedPublicationPreference(userId: 42), true)
    }
}
