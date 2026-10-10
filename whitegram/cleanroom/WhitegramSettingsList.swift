import Foundation

enum WhitegramSettingsList {
    static func filtered(_ rows: [WhitegramSettingsRowDescriptor], sections: Set<Int>?, query: String,
                         availableOnly: Bool, hideDescriptions: Bool, informationIds: Set<String>,
                         supported: (String) -> Bool, title: (WhitegramSettingsRowDescriptor) -> String) -> [WhitegramSettingsRowDescriptor] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidates = rows.filter { row in
            if let sections, !sections.contains(row.section) { return false }
            if row.kind == .headerRow { return false }
            if hideDescriptions && informationIds.contains(row.id) { return false }
            if availableOnly && !supported(row.id) { return false }
            return query.isEmpty || title(row).localizedCaseInsensitiveContains(query) || row.id.localizedCaseInsensitiveContains(query)
        }
        let ids = Set(candidates.map { $0.id })
        let populatedSections = Set(candidates.map { $0.section })
        return rows.filter { row in
            return row.kind == .headerRow ? populatedSections.contains(row.section) : ids.contains(row.id)
        }
    }
}
