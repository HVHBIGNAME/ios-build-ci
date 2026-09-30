# Settings transfer

The four recovered catalog actions are connected through the searchable/full settings catalog:
`exportSettings`, `importSettings`, `saveSettingsToKeychain`, and `restoreSettingsFromKeychain`.

## Implemented

- Native import/export document pickers, bounded coordinated reads, cancellation and temporary-file cleanup.
- An explicit configuration allowlist excludes API keys, account/session material, plugin permissions/data, media paths and unrelated defaults. Failed credential migration does not make credentials exportable.
- Strict envelope, duplicate-key, alias, type, range, size and nesting validation precedes import.
- Partial imports retain the latest values of absent settings, including privacy flags. Invalid touched stores are not replaced.
- Public-fork chat/tab/story/folder/context-menu mirrors are prepared before canonical storage is committed; notifications follow the unlocked update.
- Device-local, non-synchronizing Keychain backup with unlocked-only protection and read-back verification.
- The generated `localStarsCount` type is corrected to `Int64`, matching the recovered native getter `0x201828`. Old Boolean records read as zero unless an exact numeric primitive mirror exists. This does not change any server-side Stars balance.

The portable JSON format is **`whitegram.settings.port`, version 1**. Compatibility with the original IPA's backup format has not been established. The original action/type evidence is recorded in `FEATURE_COVERAGE.json` and `FEATURE_COVERAGE.md`; reconstructed allowlist/range rules are explicit in `WhitegramSettingsArchiveSchema.swift`.

## Integration and checks

`compat-12.9.4.py` copies the Foundation archive/schema/store into TelegramCore and the Keychain/document/UI adapters into SettingsUI. The generated settings router opens the selected action's screen.

```text
python -B whitegram/tests/settings_transfer/check_sources.py --target <assembled-source>
python -B whitegram/tests/settings_transfer/run_native.py --assembled-source <assembled-source>
```

The source check parses ten production Swift files and three XCTest files. The 29 native tests cover typed roundtrips, exact Int64 boundaries, malformed/secret-bearing imports, real public-fork model decoding, observer ordering, Keychain policy/failures and coordinated file I/O. Native execution requires an Apple Swift host; Windows parsing alone does not establish execution or UI correctness.

Compact public navigation/list modes retain their existing apply/restart requirement. The transfer format does not install fonts/plugins, restore sessions, or migrate media files.
