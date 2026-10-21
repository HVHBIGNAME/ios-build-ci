import Foundation
import XCTest
@testable import Diagnostics

final class SessionDiagnosticsTests: XCTestCase {
    func testBoundedJournalPersistsAndExportsOnlyTechnicalEvents() throws {
        let name = "WhitegramSessionDiagnosticsTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let journal = WhitegramSessionDiagnostics(defaults: defaults)
        for _ in 0..<80 { journal.record(.authorizationCommitted, datacenter: 1, code: 0) }
        journal.record(.staleLoginWriteBlocked, datacenter: 100)
        let restored = WhitegramSessionDiagnostics(defaults: defaults)
        let file = try restored.export()
        defer { try? FileManager.default.removeItem(at: file) }
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertEqual(value["schema"] as? Int, 1)
        let events = try XCTUnwrap(value["events"] as? [[String: Any]])
        XCTAssertEqual(events.count, 64)
        XCTAssertEqual(events.last?["event"] as? String, "staleLoginWriteBlocked")
        XCTAssertNil(events.last?["datacenter"])
        for event in events { XCTAssertTrue(Set(event.keys).isSubset(of: ["event", "timestamp", "datacenter", "code"])) }
    }
}
