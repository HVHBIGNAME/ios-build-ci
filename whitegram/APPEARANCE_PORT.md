# Whitegram fonts and app icons — Telegram 12.9.2

The parent assembler installs the sources, applies the font hooks and routes the main-menu entries. Current integrated verification results are in [PORT_STATUS.md](PORT_STATUS.md).

## Integration handoff

Public SettingsUI entrypoints:

```swift
public func whitegramFontsController(context: AccountContext) -> ViewController
public func whitegramIconsController(context: AccountContext) -> ViewController
```

Both return real `ItemListController` screens using the 12.9.2
`ItemListNodeEntry.item(presentationData:arguments:)` API. The fonts screen covers
the recovered `customFontsManager`, `customFontPicker`, and `fontHistoryItem`
actions in one manager. The parent menu can push these entrypoints normally.

Copy these sources into the assembled source tree **before building**:

| Clean-room source | Copy destination | Module / dependencies |
| --- | --- | --- |
| `cleanroom/WhitegramFontRegistry.swift` | `submodules/Display/Source/WhitegramFontRegistry.swift` | Display; Foundation, UIKit, CoreText only |
| `cleanroom/WhitegramFontsController.swift` | `submodules/SettingsUI/Sources/WhitegramFontsController.swift` | SettingsUI; Display, TelegramCore, ItemListUI, AccountContext, SwiftSignalKit, TelegramPresentationData; UIKit and UniformTypeIdentifiers |
| `cleanroom/WhitegramIconsController.swift` | `submodules/SettingsUI/Sources/WhitegramIconsController.swift` | SettingsUI; Display, TelegramCore, ItemListUI, AccountContext, SwiftSignalKit, TelegramPresentationData, AppBundle; UIKit |

The inspected Display and SettingsUI BUILD targets already glob those Swift
directories. All listed project-module dependencies already exist on SettingsUI.
UniformTypeIdentifiers is an Apple SDK framework; its font type and the modern
document picker are availability-guarded for iOS 14. The system font picker is
guarded for iOS 13. No TelegramCore dependency belongs on Display.

The parent assembler should import and call:

```python
from appearance_patches import apply_appearance_patches

appearance_features = apply_appearance_patches(root)
```

`appearance_patches.py` uses the existing `SourcePatches` helper and returns:

```python
{"customFonts": ["submodules/Display/Source/Font.swift"]}
```

It inserts **eight registry checks**: at the beginning of
`Font.with(size:design:weight:width:traits:)`, **before the existing cache lookup**,
and at `regular`, `medium`, `semibold`, `bold`, `light`, `semiboldItalic`, and
`italic`. `heavy` is covered through its existing delegation to `Font.with`.
Each check returns early only when an enabled custom selection can render the
request. A disabled, missing or unsupported custom face falls through to the
helper's complete original body, including availability branches and the original
system-font cache. There is no unconditional redirection of convenience methods
through `Font.with`.

The patch fails on missing/ambiguous anchors before writing, including a missing
late convenience helper. It is idempotent and upgrades the earlier with-only
patch without duplicate calls. Registry/controller
copying, the caller integration, menu wiring, resource assembly, and signing are
parent integration steps.

## Font behavior and persistence

- **System picker:** `UIFontPickerViewController.Configuration.includeFaces = true`.
  The selected descriptor's PostScript name must resolve to an available font;
  an unavailable provider font produces a visible message rather than selecting
  a substituted system face. Cancellation leaves preferences untouched.
- **File import:** `UIDocumentPickerViewController` opens font documents as copies.
  Security-scoped access and `NSFileCoordinator` cover the asynchronous import.
  Only regular, non-symlink `.ttf`/`.otf` files of 1 byte through 32 MiB are accepted.
  CoreText must successfully read descriptors and register the copied file.
  Duplicate installed PostScript names are rejected with an actionable error.
- **Storage:** files have UUID filenames in the main application's sandbox:
  `Library/Application Support/Whitegram/Fonts/<UUID>.ttf` (or `.otf`). Neither a
  document-provider URL nor an absolute container path is persisted in history.
- **Relaunch:** the Display registry scans that directory and calls
  `CTFontManagerRegisterFontsForURL(..., .process, ...)` on the first enabled general
  font request (including a convenience helper) or first opening of the font manager.
  Registration is process-scoped and repeated each launch. An active saved
  selection does not require opening the font screen first. Unreadable imports
  appear as removable unavailable rows with errors.
- **Library:** imported faces and previously selected system faces are listed;
  the most recently selected saved face is first. Importing adds faces to the
  library; tapping a face selects and enables it. The preview uses that actual
  face in an attributed ItemList text item, including when the enable switch is off.
- **Removal:** swipe left, then confirm. Imported-file removal removes every face
  in the file and resets the selection if it was active. System-font removal
  removes its history entry. CoreText unregister is attempted before deletion;
  an in-use font may remain loaded until restart, which is reported explicitly.
  The registry blocks removed names immediately. Failed file deletion preserves
  history and attempts to restore any registration it had released.
- **Reset:** disables custom fonts and clears the selection, retaining the library.

All preference writes go through the parent's `WhitegramPreferences.set/update`.

| Key | Type | Meaning |
| --- | --- | --- |
| `customFontEnabled` | Bool | Whether the runtime hook can use a selected font |
| `customFontName` | String | Exact PostScript name; empty after reset |
| `fontHistory` | `[[String: String]]` | Saved faces; maintains the recovered array-of-dictionaries type |
| `appIconName` | String | Last successfully verified app icon; empty means primary |

New font-history dictionaries use `name`, `displayName`, `source` (`system` or
`import`), and an optional `fileName` containing only the imported file's basename.
Example:

```json
[
  {
    "name": "ExampleFont-Regular",
    "displayName": "Example Font Regular",
    "source": "import",
    "fileName": "529F04C5-4571-4C19-9B64-4BB7F47DBA4D.ttf"
  }
]
```

The recovered IPA establishes the history container type, not its dictionary key
schema. Unrecognized legacy dictionary entries are retained during ordinary
updates but are not presented as valid fonts without a `name`. The current
`customFontName` is also included in the list when absent from history.

Display's hot path reads `UserDefaults.standard` primitives `wg_customFontEnabled`
and `wg_customFontName`. Selection and enable/disable actions write both settings
through the shared store, whose `update` persists the JSON snapshot and these
primitive mirrors. Those mirrors survive a normal relaunch.

The inspected `WhitegramPreferences.values()` also merges older saved data but
does not itself create missing mirrors. For an untouched migrated selection,
Display therefore has a read-only bootstrap: if a mirror is missing it decodes
the two font fields from `WhitegramSettingsState.v1`, falling back per missing
field to `WhitegramPrivacySettings.v1`, matching the shared store's precedence.
An explicit false enable mirror or empty name mirror wins over the saved snapshot.
The fallback is cached until registry invalidation; live mirrors are checked on
every request. This uses Foundation, writes no preferences and introduces no
TelegramCore dependency. The persistence paths were checked in source; actual
device termination/relaunch remains a device validation step.

The locked, bounded font cache includes name, size, weight and traits. Selection
changes, enable/disable, import, deletion and reset cannot reuse the previous
selection's cache entry. Existing attributed text still requires recreation.

`regular` and the preview retain the selected face's own style. The weighted
helpers request their named weight in that family; `italic` adds the italic trait,
and `semiboldItalic` requests semibold plus italic. The preview deliberately uses
the selected face even when customization is off; it is not an enabled-state test.
Family/weight/italic matching uses public UIFontDescriptor attributes. If the
requested italic or light/heavier face cannot be represented in the selected
family, that helper's original Telegram fallback handles it. All four explicit
monospace helpers retain their original bodies. `.monospace`, `.camera`,
`.monospacedNumbers`, and nonstandard width requests to `Font.with` also retain
their original path. No global swizzling is used.

## Bundled app icons

The picker reads `Bundle.main.infoDictionary` for `CFBundleIcons`, or
`CFBundleIcons~ipad` on iPad, and enumerates its `CFBundleAlternateIcons`. App
bindings supply preview metadata. A name found only in bindings is not offered.
Previews first use the actual plist's icon files/asset name, with binding images
as a fallback. A primary row always maps to a **nil** alternate name.

The public resource set inspected for this port has **Default plus 13 alternates**:
Aqua, Aura, Azure, Chrome, Crystal, Depth, Frost, Glow, MonoDark, MonoLite,
NeonWawe, Obsidian, and Steel. Preserve the spelling `NeonWawe` in plist keys.
Default is the primary icon, not the string `"Default"` passed to UIKit.

Parent-owned resource/declaration paths, relative to the Telegram source root:

- `Telegram/Telegram-iOS/AppIcons.xcassets/<Name>.appiconset/`
- `Telegram/Telegram-iOS/DefaultAppIcon.xcassets/`
- `Telegram/Telegram-iOS/Icons.xcassets/`
- `Telegram/Telegram-iOS/<AlternateName>.alticon/*.png`
- `Telegram/Telegram-iOS/AlternateIcons.plist`
- `Telegram/Telegram-iOS/AlternateIcons-iPad.plist`
- `Telegram/Telegram-iOS/AddAlternateIcons.sh` and `Telegram/BUILD`

The two alternate-icon dictionaries must be merged into the final signed app's
Info.plist and their image resources packaged. The screen discovers the installed
bundle dynamically, including the target `whitegram.telegra.Telegraph`; it has
no hardcoded bundle identifier or hardcoded availability list.

Switching uses documented `UIApplication.setAlternateIconName(_:completionHandler:)`
and `supportsAlternateIcons`, restricted to the main app. Selection is disabled
during a request. The checkmark always comes from `UIApplication.alternateIconName`,
never from optimistic preference state. Completion is delivered back to the main
queue; errors/cancellation are shown, and the preference mirror is saved only
after error-free completion with a matching system value. Foregrounding and
screen appearance re-read system state, including changes made elsewhere.

## Lifecycle

Each ItemListController retains its coordinator through its state signal and
`didAppear` closure. The font coordinator's controller reference is weak; native
picker delegates therefore stay alive throughout presentation without an
associated-object registry or a global controller reference. Observers use weak
captures and are removed in deinit. A remaining native picker is dismissed on
the main queue if its font-manager owner is released. Background file operations
and icon completion callbacks retain their coordinator until completion.

## Verification

Run from the parent build repository, with bytecode writes disabled:

```powershell
$env:WHITEGRAM_APPEARANCE_SOURCE = 'C:\Users\Pisun4ik\AppData\Local\Temp\opencode\whitegram-port-12.9.2'
& 'C:\Users\Pisun4ik\AppData\Local\Temp\opencode\whitegram-check-env\Scripts\python.exe' -B -m unittest discover -s 'whitegram\tests' -p 'test_appearance_patches.py' -v
```

The tests execute the real patch helper against an **in-memory filesystem**:
all eight insertion points, per-helper weights and italic traits, preservation of
each disabled/unsupported fallback body, heavy delegation, all four monospace
helpers, idempotency, missing file, absent/ambiguous anchors, late-anchor atomic
failure, unrelated-file isolation and CRLF handling. With
`WHITEGRAM_APPEARANCE_SOURCE` set they test the complete 12.9.2 Font.swift in memory
as pristine, with-only patched, and currently assembled inputs. Tree-sitter 0.25.2 with Swift grammar 0.7.3 parses the
three new Swift files and the patched Font.swift. No test writes to the source
checkout or creates a fixture directory.

Verified against the supplied assembled 12.9.2 tree with the parser environment:
**14 tests passed, none skipped**, including both syntax tests. The full-source
check requires the environment variable shown above.

API checks used the actual 12.9.2 ItemListUI, AccountContext, PresentationAppIcon,
AppBundle and Font sources, and Apple's declarations for the font-picker delegate
and CoreText URL registration. Tree-sitter validation is syntax validation, not a
Swift typecheck or an iOS build. No local Xcode/Swift compiler is available.

Device/build follow-up: build both targets, open the screens, cancel both font
pickers, import valid/invalid/duplicate fonts, select a face, relaunch, toggle and
reset, delete an active import, exercise weight/italic rendering through Font.with
and all general convenience helpers (also with customization disabled),
and switch/default app icons on iPhone and iPad while checking failure behavior.

## Remaining limits

- General `Font` helpers are covered, including `regular`, `bold`, `italic` and
  `heavy`. Direct UIFont construction outside these helpers remains outside the
  hook. Existing attributed strings need recreation/re-layout; there is no global
  live-text invalidation or swizzling.
- Font libraries are per application sandbox, not shared into app extensions.
  Provider fonts must actually be installed/available; only a PostScript face
  name is persisted, not custom variable-font axes or remote-provider downloads.
- App icon selection is functional with bundled resources. The recovered
  `customSettingsIcons` setting and remote icon-pack search/upload/services have
  no established service contract in this slice and are **not implemented**.
  No remote pack action is presented as working.
- The controllers currently use English UI copy. Native picker localization and
  Telegram's localized Back button remain available.
