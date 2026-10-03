import Foundation
import XCTest
@testable import WhitegramBackendHost

final class WhitegramProfileStateTests: XCTestCase {
    private let about = Data(#"{"enabled":true,"text":"fixture","entities":[]}"#.utf8)

    func testSuccessfulSaveInvalidatesAnOlderInFlightFetch() {
        let fixture = BackendFixture()
        let service = WhitegramProfileService(client: fixture.client, now: { fixture.date })
        let stale = expectation(description: "stale read rejected")
        service.fetch(WhitegramProfileAbout.self, resource: .about, userId: 42) { result in
            XCTAssertEqual(result.failure, .staleResponse)
            stale.fulfill()
        }
        let saved = expectation(description: "saved")
        service.save(WhitegramProfileAbout(enabled: true, text: "new value", entities: [], image: nil), path: "/v1/profile/about") { result in
            XCTAssertNil(result.failure)
            saved.fulfill()
        }
        fixture.http.respond(1)
        wait(for: [saved], timeout: 1)
        fixture.http.respond(0, data: about)
        wait(for: [stale], timeout: 1)
        service.fetch(WhitegramProfileAbout.self, resource: .about, userId: 42) { _ in }
        XCTAssertEqual(fixture.http.calls.count, 3)
        fixture.http.respond(2, data: about)
    }

    func testCacheCannotOutliveAccessOrSessionAndUsesOriginalLifetime() {
        let fixture = BackendFixture()
        let service = WhitegramProfileService(client: fixture.client, now: { fixture.date })
        let fetched = expectation(description: "fetch")
        service.fetch(WhitegramProfileAbout.self, resource: .about, userId: 42) { result in
            XCTAssertEqual(try? result.get().text, "fixture")
            fetched.fulfill()
        }
        fixture.http.respond(0, data: about)
        waitForExpectations(timeout: 1)
        let cached = expectation(description: "cache hit")
        service.fetch(WhitegramProfileAbout.self, resource: .about, userId: 42) { result in
            XCTAssertEqual(try? result.get().text, "fixture")
            cached.fulfill()
        }
        waitForExpectations(timeout: 1)
        XCTAssertEqual(fixture.http.calls.count, 1)
        fixture.grantFixtureAccess(allowed: false)
        let denied = expectation(description: "no cached data after denial")
        service.fetch(WhitegramProfileAbout.self, resource: .about, userId: 42) { result in
            XCTAssertEqual(result.failure, .betaAccessDenied)
            denied.fulfill()
        }
        waitForExpectations(timeout: 1)
        XCTAssertEqual(fixture.http.calls.count, 1)
        fixture.grantFixtureAccess()
        fixture.sessions.values[42] = fixture.session(token: "replacement-fixture")
        service.fetch(WhitegramProfileAbout.self, resource: .about, userId: 42) { _ in }
        XCTAssertEqual(fixture.http.calls.count, 2)
        fixture.http.respond(1, data: about)
        XCTAssertEqual(WhitegramProfileResource.registration.cacheLifetime, 600)
        XCTAssertEqual(WhitegramProfileResource.about.cacheLifetime, 120)
        XCTAssertEqual(WhitegramProfileResource.badge.cacheLifetime, 5)
    }

    func testStrictModelValidationRejectsSurrogateSplitsAndDuplicateWallIds() throws {
        for (text, offset, length, valid) in [
            ("😀", 1, 1, false), ("😀", 0, 1, false), ("😀", 0, 2, true),
            ("a😀b", 1, 2, true), ("a😀b", 3, 1, true),
            ("e\u{301}", 1, 1, true), ("text", 4, 1, false),
            ("text", -1, 1, false), ("text", 0, 0, false),
            ("text", 1, Int.max, false), ("text", Int.max, 1, false)
        ] {
            let entity = WhitegramProfileTextEntity(offset: offset, length: length, type: "bold", url: nil, documentId: nil)
            XCTAssertEqual(entity.isValid(in: text), valid, "Unexpected UTF-16 range validation at \(offset), length \(length), in \(text)")
        }
        let malformed = Data(#"{"enabled":true,"text":"😀","entities":[{"offset":1,"length":1,"type":"bold"}]}"#.utf8)
        XCTAssertThrowsError(try WhitegramBackendDecoding.decode(WhitegramProfileAbout.self, from: malformed))
        let message = WhitegramProfileWallMessage(id: "same", wallOwnerId: 42, authorId: 43, authorName: "Fixture", text: "Message", entities: [], timestamp: 1700000000, editedAt: nil)
        let state = WhitegramProfileWallState(enabled: true, messages: [message, message], nextAllowedAt: nil, blocked: false)
        XCTAssertThrowsError(try WhitegramBackendDecoding.decode(WhitegramProfileWallState.self, from: JSONEncoder().encode(state)))
        XCTAssertFalse(WhitegramProfileWallState(enabled: true, messages: [], nextAllowedAt: 1700000001, blocked: false).canPost(at: Date(timeIntervalSince1970: 1700000000)))
        XCTAssertFalse(WhitegramProfileWallState(enabled: true, messages: [], nextAllowedAt: nil, blocked: true).canPost(at: Date()))
    }

    func testRegistrationDateKeepsPartialPrecisionAndRejectsInvalidCalendarDates() throws {
        for (year, month, day) in [(0, 0, 0), (2019, 0, 0), (2020, 2, 0), (2020, 2, 29)] {
            XCTAssertTrue(WhitegramProfileRegistrationDate.validDate(year: year, month: month, day: day))
        }
        for (year, month, day) in [(2019, 2, 29), (2020, 4, 31), (2019, 0, 1), (0, 1, 0), (-1, 0, 0)] {
            XCTAssertFalse(WhitegramProfileRegistrationDate.validDate(year: year, month: month, day: day))
        }
        let fixture = BackendFixture()
        let service = WhitegramProfileService(client: fixture.client)
        let task = try service.saveRegistrationDate(year: 2019, month: 0, day: 0) { _ in }
        let body = try XCTUnwrap(fixture.http.calls[0].request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Int])
        XCTAssertEqual(json, ["year": 2019, "month": 0, "day": 0])
        XCTAssertEqual(fixture.http.calls[0].request.url?.path, "/v1/registration-date")
        task.cancel()
        fixture.http.respond(0)
    }

    func testPhotoSlotsAndJPEGPayloadAreAccountBound() throws {
        let fixture = BackendFixture()
        let photos = WhitegramProfilePhotosService(client: fixture.client)
        XCTAssertThrowsError(try photos.setPhoto(Data([0, 1, 2]), slot: 0) { _ in })
        XCTAssertThrowsError(try photos.setPhoto(Data([255, 216, 255]), slot: 3) { _ in })
        let task = try photos.setPhoto(Data([255, 216, 255, 0]), slot: 2) { _ in }
        XCTAssertEqual(fixture.http.calls[0].request.httpMethod, "POST")
        XCTAssertEqual(fixture.http.calls[0].request.url?.query, "slot=2")
        XCTAssertEqual(fixture.http.calls[0].request.value(forHTTPHeaderField: "Content-Type"), "image/jpeg")
        XCTAssertEqual(fixture.http.calls[0].request.value(forHTTPHeaderField: "Authorization"), "Whitegram synthetic-token")
        task.cancel(); fixture.http.respond(0)
    }
}

final class WhitegramStreakTests: XCTestCase {
    func testReportsWaitForServerSettingsAndKeepFailedWorkUntilRetryOrDisable() throws {
        let fixture = BackendFixture()
        var enabled = true
        let session = WhitegramProfileStreakSession(client: fixture.client, enabled: { enabled }, now: { fixture.date })
        let event = WhitegramBackendMessageEvent(accountId: 42, peerId: 43, messageId: 1, timestamp: 1700000000, direction: .sent)
        session.enqueue(event)
        XCTAssertEqual(fixture.http.calls.count, 1)
        XCTAssertEqual(fixture.http.calls[0].request.url?.path, "/v1/streak/settings")
        XCTAssertEqual(session.pendingCount, 1)
        fixture.http.respond(0)
        let synchronized = expectation(description: "settings before event")
        DispatchQueue.main.async {
            XCTAssertEqual(fixture.http.calls.count, 2)
            XCTAssertEqual(fixture.http.calls[1].request.url?.path, "/v1/streak/event")
            XCTAssertEqual(session.synchronizedEnabled, true)
            synchronized.fulfill()
        }
        waitForExpectations(timeout: 1)
        fixture.http.calls[1].completion(.failure(.transport(-1009)))
        let retained = expectation(description: "failed event retained")
        DispatchQueue.main.async {
            XCTAssertEqual(session.pendingCount, 1)
            XCTAssertEqual(session.lastError, .transport(-1009))
            enabled = false
            session.settingsDidChange()
            XCTAssertEqual(session.pendingCount, 0)
            XCTAssertEqual(fixture.http.calls.count, 3)
            XCTAssertEqual(fixture.http.calls[2].request.url?.path, "/v1/streak/settings")
            retained.fulfill()
        }
        waitForExpectations(timeout: 1)
        let body = try XCTUnwrap(fixture.http.calls[2].request.httpBody)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: body) as? [String: Bool], ["enabled": false])
        fixture.http.respond(2)
    }

    func testThrottleScopesToPeerDirectionAccountAndElapsedTime() {
        var throttle = WhitegramProfileStreakThrottle()
        let event = WhitegramBackendMessageEvent(accountId: 42, peerId: 43, messageId: 1, timestamp: 1700000000, direction: .sent)
        let date = Date(timeIntervalSince1970: 1700000000)
        XCTAssertFalse(throttle.accept(event, accountId: 44, enabled: true, now: date))
        XCTAssertFalse(throttle.accept(event, accountId: 42, enabled: false, now: date))
        XCTAssertTrue(throttle.accept(event, accountId: 42, enabled: true, now: date))
        XCTAssertFalse(throttle.accept(event, accountId: 42, enabled: true, now: date.addingTimeInterval(61)))
        let next = WhitegramBackendMessageEvent(accountId: 42, peerId: 43, messageId: 2, timestamp: 1700000001, direction: .sent)
        XCTAssertFalse(throttle.accept(next, accountId: 42, enabled: true, now: date.addingTimeInterval(59)))
        XCTAssertTrue(throttle.accept(next, accountId: 42, enabled: true, now: date.addingTimeInterval(60)))
        let received = WhitegramBackendMessageEvent(accountId: 42, peerId: 43, messageId: 3, timestamp: 1700000001, direction: .received)
        XCTAssertTrue(throttle.accept(received, accountId: 42, enabled: true, now: date.addingTimeInterval(60)))
    }

    func testEventWirePayloadUsesOriginalTimestampAndHistoricalTimezoneOffset() throws {
        let event = WhitegramProfileStreakEvent(peerId: 43, timestamp: 1700000000, timeZone: TimeZone(secondsFromGMT: 19800)!)
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(event)) as? [String: Int64]
        XCTAssertEqual(object, ["peer_id": 43, "event_timestamp": 1700000000, "timezone_offset": 19800])
    }
}
