import XCTest
@testable import SettingsUI

final class WhitegramSettingsListTests: XCTestCase {
    private func row(_ id: String, _ order: Int, _ section: Int, _ kind: WhitegramSettingsRowKind) -> WhitegramSettingsRowDescriptor {
        return WhitegramSettingsRowDescriptor(id: id, order: order, section: section, kind: kind, title: id, labelsVerified: false)
    }

    private var rows: [WhitegramSettingsRowDescriptor] {
        return [row("firstHeader", 0, 1, .headerRow), row("firstSwitch", 1, 1, .switchRow), row("help", 2, 1, .textRow),
                row("secondHeader", 3, 2, .headerRow), row("unsupported", 4, 2, .switchRow), row("emptyHeader", 5, 3, .headerRow)]
    }

    private func filtered(query: String = "", sections: Set<Int>? = nil, availableOnly: Bool = true, hideDescriptions: Bool = false) -> [String] {
        return WhitegramSettingsList.filtered(rows, sections: sections, query: query, availableOnly: availableOnly,
            hideDescriptions: hideDescriptions, informationIds: ["help"], supported: { ["firstSwitch", "help"].contains($0) },
            title: { $0.id == "firstSwitch" ? "Скрыть номер" : $0.title }).map { $0.id }
    }

    func test_available_rows_keep_their_header_but_not_empty_sections() {
        XCTAssertEqual(filtered(), ["firstHeader", "firstSwitch", "help"])
    }
    func test_all_settings_retains_unsupported_rows() {
        XCTAssertEqual(filtered(availableOnly: false), ["firstHeader", "firstSwitch", "help", "secondHeader", "unsupported"])
    }
    func test_query_matches_localized_text_and_preserves_context() {
        XCTAssertEqual(filtered(query: "  СКРЫТЬ  "), ["firstHeader", "firstSwitch"])
        XCTAssertEqual(filtered(query: "firstSwitch"), ["firstHeader", "firstSwitch"])
        XCTAssertTrue(filtered(query: "missing").isEmpty)
    }
    func test_section_filter_cannot_leak_an_unrelated_header() {
        XCTAssertTrue(filtered(sections: [2]).isEmpty)
        XCTAssertEqual(filtered(sections: [2], availableOnly: false), ["secondHeader", "unsupported"])
    }
    func test_description_preference_removes_only_explicit_help_rows() {
        XCTAssertEqual(filtered(hideDescriptions: true), ["firstHeader", "firstSwitch"])
        XCTAssertTrue(filtered(query: "help", hideDescriptions: true).isEmpty)
    }
}
