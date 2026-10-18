import Foundation
import XCTest
@testable import WhitegramBackendHost

final class WhitegramProfileMetadataCardTests: XCTestCase {
    private func drain() {
        let done = expectation(description: "main queue callbacks")
        DispatchQueue.main.async { done.fulfill() }
        wait(for: [done], timeout: 1)
    }

    private func adapter(_ fixture: BackendFixture) -> WhitegramPeerMetadataCardAdapter {
        drain() // The fixture's initial access grant posts asynchronously.
        return WhitegramPeerMetadataCardAdapter(client: fixture.client, automaticallyRefresh: false)
    }

    private func payload(userId: Int64 = 43, year: Int = 2020, month: Int = 2, day: Int = 29, exact: Bool = true) -> Data {
        return Data("{\"user_id\":\(userId),\"year\":\(year),\"month\":\(month),\"day\":\(day),\"exact\":\(exact)}".utf8)
    }

    func testTelegramMonthWinsWithoutSessionOrAccess() {
        let fixture = BackendFixture(allowed: nil)
        fixture.sessions.values.removeAll()
        let card = adapter(fixture)
        card.update(userId: 43, telegramMonth: "02.2020", enabled: true)
        XCTAssertEqual(card.date, WhitegramPeerMetadataDate(year: 2020, month: 2, day: 0, exact: true))
        XCTAssertTrue(fixture.http.calls.isEmpty)
        card.update(userId: 43, telegramMonth: "02.2020", enabled: false)
        XCTAssertNil(card.date)
        card.update(userId: nil, telegramMonth: "02.2020", enabled: true)
        XCTAssertNil(card.date)
        card.update(userId: -1, telegramMonth: "02.2020", enabled: true)
        XCTAssertNil(card.date)
    }

    func testMalformedTelegramMonthFallsBackToAuthenticatedTargetRequest() {
        let fixture = BackendFixture()
        let card = adapter(fixture)
        var changes = 0
        card.updated = { changes += 1 }
        for _ in 0..<3 { card.update(userId: 43, telegramMonth: "13.2020", enabled: true) }
        XCTAssertEqual(fixture.http.calls.count, 1)
        let request = fixture.http.calls[0].request
        XCTAssertEqual(request.url?.path, "/v1/registration-date")
        XCTAssertEqual(request.url?.query, "user_id=43")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Whitegram synthetic-token")
        fixture.http.respond(0, data: payload())
        drain()
        XCTAssertEqual(card.date?.formatted { _, _ in "unused" }, "29.02.2020")
        XCTAssertEqual(changes, 1)
        card.update(userId: 43, telegramMonth: "13.2020", enabled: true)
        card.refreshIfNeeded()
        XCTAssertEqual(fixture.http.calls.count, 1)
    }

    func testTargetChangeCancelsAndIgnoresObsoleteResult() {
        let fixture = BackendFixture()
        let card = adapter(fixture)
        card.update(userId: 43, telegramMonth: nil, enabled: true)
        card.update(userId: 44, telegramMonth: nil, enabled: true)
        XCTAssertTrue(fixture.http.calls[0].task.cancelled)
        fixture.http.respond(0, data: payload())
        drain()
        XCTAssertNil(card.date)
        fixture.http.respond(1, data: payload(userId: 44, year: 2019, month: 0, day: 0, exact: false))
        drain()
        XCTAssertEqual(card.date?.formatted { _, _ in "unused" }, "~ 2019")
    }

    func testDisableAndReenableSameTargetDoesNotAcceptOldGeneration() {
        let fixture = BackendFixture()
        let card = adapter(fixture)
        card.update(userId: 43, telegramMonth: nil, enabled: true)
        card.update(userId: 43, telegramMonth: nil, enabled: false)
        card.update(userId: 43, telegramMonth: nil, enabled: true)
        XCTAssertEqual(fixture.http.calls.count, 2)
        fixture.http.respond(0, data: payload(year: 2019, month: 0, day: 0))
        drain()
        XCTAssertNil(card.date)
        fixture.http.respond(1, data: payload())
        drain()
        XCTAssertEqual(card.date?.year, 2020)
    }

    func testTelegramDataArrivingDuringFetchCancelsFallback() {
        let fixture = BackendFixture()
        let card = adapter(fixture)
        card.update(userId: 43, telegramMonth: nil, enabled: true)
        card.update(userId: 43, telegramMonth: "03.2021", enabled: true)
        XCTAssertTrue(fixture.http.calls[0].task.cancelled)
        fixture.http.respond(0, data: payload())
        drain()
        XCTAssertEqual(card.date?.year, 2021)
        XCTAssertEqual(card.date?.month, 3)
        XCTAssertEqual(card.date?.day, 0)
    }

    func testEmptyMalformedAndWrongUserResponsesNeverProduceCardOrRequestLoop() {
        let invalid = [payload(year: 0, month: 0, day: 0), payload(userId: 44), payload(year: 2019),
            Data("{}".utf8), Data("{\"user_id\":43,\"year\":\"2020\"}".utf8)]
        for data in invalid {
            let fixture = BackendFixture()
            let card = adapter(fixture)
            card.update(userId: 43, telegramMonth: nil, enabled: true)
            fixture.http.respond(0, data: data)
            drain()
            XCTAssertNil(card.date)
            card.update(userId: 43, telegramMonth: nil, enabled: true)
            XCTAssertEqual(fixture.http.calls.count, 1)
            card.cancel()
        }
    }

    func testMutationFromAnotherServiceInvalidatesPendingReadAndReloads() {
        let fixture = BackendFixture()
        let card = adapter(fixture)
        card.update(userId: 43, telegramMonth: nil, enabled: true)
        let otherService = WhitegramProfileService(client: fixture.client)
        let mutation = otherService.save(WhitegramProfileRequests.Enabled(enabled: true), path: "/v1/profile/badge") { _ in }
        fixture.http.respond(1)
        drain()
        XCTAssertTrue(fixture.http.calls[0].task.cancelled)
        XCTAssertEqual(fixture.http.calls.count, 3)
        fixture.http.respond(0, data: payload(year: 2019, month: 0, day: 0))
        drain()
        XCTAssertNil(card.date)
        fixture.http.respond(2, data: payload())
        drain()
        XCTAssertEqual(card.date?.year, 2020)
        withExtendedLifetime(mutation) {}
    }

    func testUnrelatedAccountNotificationDoesNotCancelOrReload() {
        let fixture = BackendFixture()
        let card = adapter(fixture)
        card.update(userId: 43, telegramMonth: nil, enabled: true)
        for name in [WhitegramBackendClient.sessionUpdated, WhitegramBackendAccessStore.updated] {
            NotificationCenter.default.post(name: name, object: nil, userInfo: ["userId": Int64(99)])
        }
        NotificationCenter.default.post(name: WhitegramProfileService.updated, object: nil, userInfo: ["accountId": Int64(99)])
        XCTAssertFalse(fixture.http.calls[0].task.cancelled)
        XCTAssertEqual(fixture.http.calls.count, 1)
        fixture.http.respond(0, data: payload())
        drain()
        XCTAssertNotNil(card.date)
    }

    func testLogoutImmediatelyHidesSnapshotAndReconnectRefetches() {
        let fixture = BackendFixture()
        let card = adapter(fixture)
        card.update(userId: 43, telegramMonth: nil, enabled: true)
        fixture.http.respond(0, data: payload())
        drain()
        fixture.sessions.values.removeAll()
        XCTAssertNil(card.date)
        NotificationCenter.default.post(name: WhitegramBackendClient.sessionUpdated, object: nil, userInfo: ["userId": Int64(42)])
        XCTAssertNil(card.date)
        XCTAssertEqual(fixture.http.calls.count, 1)
        fixture.sessions.values[42] = fixture.session(token: "new-session")
        NotificationCenter.default.post(name: WhitegramBackendClient.sessionUpdated, object: nil, userInfo: ["userId": Int64(42)])
        XCTAssertEqual(fixture.http.calls.count, 2)
        XCTAssertNil(card.date)
        fixture.http.respond(1, data: payload())
        drain()
        XCTAssertNotNil(card.date)
    }

    func testExpiredAccessIsNotDisplayedEvenWithoutNotification() {
        let fixture = BackendFixture()
        let card = adapter(fixture)
        card.update(userId: 43, telegramMonth: nil, enabled: true)
        fixture.http.respond(0, data: payload())
        drain()
        XCTAssertNotNil(card.date)
        var changes = 0
        card.updated = { changes += 1 }
        fixture.date = fixture.date.addingTimeInterval(601)
        XCTAssertNil(card.date)
        card.refreshIfNeeded()
        XCTAssertEqual(changes, 1)
        XCTAssertEqual(fixture.http.calls.count, 1)
    }

    func testDeniedAccessAndExpiredPendingResponseCannotProduceDate() {
        let fixture = BackendFixture(allowed: false)
        let card = adapter(fixture)
        card.update(userId: 43, telegramMonth: nil, enabled: true)
        XCTAssertTrue(fixture.http.calls.isEmpty)
        fixture.grantFixtureAccess()
        drain()
        XCTAssertEqual(fixture.http.calls.count, 1)
        fixture.date = fixture.date.addingTimeInterval(601)
        fixture.http.respond(0, data: payload())
        drain()
        XCTAssertNil(card.date)
    }

    func testRetryAfterBoundsRepeatedLayoutAndTimerRequests() {
        let fixture = BackendFixture()
        let card = adapter(fixture)
        card.update(userId: 43, telegramMonth: nil, enabled: true)
        fixture.http.respond(0, status: 429, headers: ["Retry-After": "120"])
        drain()
        fixture.date = fixture.date.addingTimeInterval(119)
        card.refreshIfNeeded()
        card.update(userId: 43, telegramMonth: nil, enabled: true)
        XCTAssertEqual(fixture.http.calls.count, 1)
        fixture.date = fixture.date.addingTimeInterval(2)
        card.refreshIfNeeded()
        XCTAssertEqual(fixture.http.calls.count, 2)
        card.cancel()
        XCTAssertTrue(fixture.http.calls[1].task.cancelled)
    }

    func testTeardownCancelsRequestWithoutRetainingScreenAdapter() {
        let fixture = BackendFixture()
        weak var reference: WhitegramPeerMetadataCardAdapter?
        autoreleasepool {
            let card = adapter(fixture)
            reference = card
            card.update(userId: 43, telegramMonth: nil, enabled: true)
        }
        XCTAssertNil(reference)
        XCTAssertTrue(fixture.http.calls[0].task.cancelled)
        fixture.http.respond(0, data: payload())
        drain()
    }
}
