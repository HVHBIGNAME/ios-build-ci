import Foundation
import XCTest
@testable import WhitegramBackendHost

final class WhitegramBackendMigrationTests: XCTestCase {
    func testLegacySessionMovesOnlyAfterVerifiedCredentialSave() throws {
        let suite = "WhitegramBackendMigrationTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("legacy-fixture", forKey: "wg_apiSessionToken_42")
        defaults.set(1700000300.0, forKey: "wg_apiSessionExpires_42")
        defaults.set("AAECAwQ=", forKey: "wg_apiSessionKey_42")
        defaults.set("other-account", forKey: "wg_apiSessionToken_43")
        let sessions = BackendMemorySessions()
        let now = Date(timeIntervalSince1970: 1700000000)
        sessions.saveError = .keychain(-1)
        XCTAssertThrowsError(try WhitegramBackendSessionMigration.migrate(userId: 42, defaults: defaults, storage: sessions, now: now))
        XCTAssertEqual(defaults.string(forKey: "wg_apiSessionToken_42"), "legacy-fixture")
        sessions.saveError = nil
        XCTAssertEqual(try WhitegramBackendSessionMigration.migrate(userId: 42, defaults: defaults, storage: sessions, now: now), .imported)
        XCTAssertEqual(sessions.values[42]?.sessionKey, Data([0, 1, 2, 3, 4]))
        XCTAssertNil(defaults.object(forKey: "wg_apiSessionToken_42"))
        XCTAssertNil(defaults.object(forKey: "wg_apiSessionExpires_42"))
        XCTAssertNil(defaults.object(forKey: "wg_apiSessionKey_42"))
        XCTAssertEqual(defaults.string(forKey: "wg_apiSessionToken_43"), "other-account")
    }

    func testExpiredOrMalformedLegacySessionIsNotDeletedOrGrantedAccess() throws {
        let suite = "WhitegramBackendMigrationTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("legacy-fixture", forKey: "wg_apiSessionToken_42")
        defaults.set(true, forKey: "wg_apiSessionExpires_42")
        let sessions = BackendMemorySessions()
        let now = Date(timeIntervalSince1970: 1700000000)
        XCTAssertThrowsError(try WhitegramBackendSessionMigration.migrate(userId: 42, defaults: defaults, storage: sessions, now: now))
        defaults.set(1699999999.0, forKey: "wg_apiSessionExpires_42")
        XCTAssertEqual(try WhitegramBackendSessionMigration.migrate(userId: 42, defaults: defaults, storage: sessions, now: now), .expired)
        XCTAssertTrue(sessions.values.isEmpty)
        XCTAssertEqual(defaults.string(forKey: "wg_apiSessionToken_42"), "legacy-fixture")
    }

    func testScammerCacheIsNotInventedFromMissingOrCorruptData() throws {
        let suite = "WhitegramScammerTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let database = WhitegramScammerDatabase(defaults: defaults)
        XCTAssertNil(try database.snapshot())
        defaults.set([42], forKey: WhitegramScammerDatabase.cacheKey)
        XCTAssertThrowsError(try database.snapshot())
        defaults.set("42,43,42,invalid,-1", forKey: WhitegramScammerDatabase.cacheKey)
        let snapshot = try XCTUnwrap(database.snapshot())
        XCTAssertEqual(snapshot.ids, [42, 43])
        XCTAssertEqual(snapshot.ignoredEntries, 2)
        XCTAssertNil(snapshot.savedAt)
    }
}

final class WhitegramRadioAndTrafficTests: XCTestCase {
    func testRadioStopAndRestartCannotReorderHeartbeats() throws {
        let fixture = BackendFixture()
        let publisher = WhitegramRadioHeartbeatPublisher(client: fixture.client, now: { fixture.date }, updated: { _ in })
        publisher.update(playing: true)
        publisher.update(playing: false)
        XCTAssertEqual(fixture.http.calls.count, 1)
        fixture.http.respond(0)
        let stopped = expectation(description: "stop follows playing response")
        DispatchQueue.main.async {
            XCTAssertEqual(fixture.http.calls.count, 2)
            publisher.update(playing: true)
            XCTAssertEqual(fixture.http.calls.count, 2)
            fixture.http.respond(1)
            DispatchQueue.main.async {
                XCTAssertEqual(fixture.http.calls.count, 3)
                stopped.fulfill()
            }
        }
        waitForExpectations(timeout: 1)
        let values = try fixture.http.calls.map { try JSONSerialization.jsonObject(with: XCTUnwrap($0.request.httpBody)) as? [String: Bool] }
        XCTAssertEqual(values.compactMap { $0?["playing"] }, [true, false, true])
        fixture.http.respond(2)
    }

    func testRadioMetadataAndCoarsePresenceDoNotInventTrackDetails() throws {
        let frame = Data(#"{"current":{"europaplus":{"artist":"Fixture artist","title":"Fixture title","coverImageUrl300":"https://example.invalid/cover.jpg"}}}"#.utf8)
        let track = try XCTUnwrap(WhitegramRadioMetadata.emg(frame, channel: "europaplus"))
        XCTAssertEqual(track.artist, "Fixture artist")
        XCTAssertEqual(WhitegramRadioMetadata.icy("StreamTitle='Fixture artist - Fixture title';")?.title, "Fixture title")
        XCTAssertNil(try WhitegramRadioMetadata.emg(frame, channel: "dorognoe"))
        let station = WhitegramRadioStation.all[0]
        let coarse = WhitegramProfilePresenceUpdate.radio(station: station, track: track, precise: false)
        XCTAssertNil(coarse.text)
        XCTAssertNil(coarse.extra)
        XCTAssertFalse(coarse.exact)
        XCTAssertEqual(WhitegramProfilePresenceUpdate.radio(station: station, track: track, precise: true).extra?.station, station.name)
        XCTAssertThrowsError(try WhitegramRadioMetadata.subscription(channel: "unrecognized"))
    }

    func testTrafficSuspendsForBackgroundPowerAndLowBatteryAndOnlyUsesOriginalAllowlist() {
        XCTAssertEqual(WhitegramTrafficPolicy.suspension(enabled: false, foreground: true, lowPower: false, battery: 1), .disabled)
        XCTAssertEqual(WhitegramTrafficPolicy.suspension(enabled: true, foreground: false, lowPower: false, battery: 1), .background)
        XCTAssertEqual(WhitegramTrafficPolicy.suspension(enabled: true, foreground: true, lowPower: true, battery: 1), .lowPower)
        XCTAssertEqual(WhitegramTrafficPolicy.suspension(enabled: true, foreground: true, lowPower: false, battery: 0.19), .lowBattery)
        XCTAssertNil(WhitegramTrafficPolicy.suspension(enabled: true, foreground: true, lowPower: false, battery: 0.2))
        XCTAssertNil(WhitegramTrafficPolicy.suspension(enabled: true, foreground: true, lowPower: false, battery: -1))
        let agent = WhitegramTrafficPolicy.userAgents[0]
        XCTAssertNil(WhitegramTrafficPolicy.request(endpoint: "https://unexpected.invalid", userAgent: agent, head: true))
        let request = WhitegramTrafficPolicy.request(endpoint: WhitegramTrafficPolicy.endpoints[0], userAgent: agent, head: true)
        XCTAssertEqual(request?.httpMethod, "HEAD")
        XCTAssertNil(request?.httpBody)
        XCTAssertNil(request?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(WhitegramTrafficPolicy.delay, 60...180)
    }
}
