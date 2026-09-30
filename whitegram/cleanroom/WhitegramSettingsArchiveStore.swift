import Foundation

public enum WhitegramSettingsArchiveStore {
    public static func exportSettings(date: Date = Date()) throws -> WhitegramSettingsArchiveExport {
        return try WhitegramPreferences.readForTransfer { defaults, preferences in
            let snapshot = try WhitegramSettingsArchiveMirrors.capture(preferences: preferences, defaults: defaults)
            return try WhitegramSettingsArchive.export(values: snapshot, date: date)
        }
    }

    public static func importSettings(_ archive: WhitegramSettingsArchive) throws -> WhitegramSettingsArchiveImportResult {
        // Review may have happened earlier. The transaction reads the latest settings,
        // so absent keys (including privacy flags) are never restored from a stale copy.
        return try WhitegramPreferences.updateForTransfer { defaults, _ in
            let values = try WhitegramSettingsArchiveSchema.validate(archive.values).values
            let prepared = try WhitegramSettingsArchiveMirrors.prepare(values, defaults: defaults)
            let restart = values["compactChatList"] != nil || values["hideBottomTabBar"] != nil
            let result = WhitegramSettingsArchiveImportResult(importedKeys: values.keys.sorted(), restartRecommended: restart)
            return (result, prepared.changes, prepared.mirrors, prepared.notifications)
        }
    }
}
