# Whitegram appearance — Telegram 12.9.2

The parent assembler installs the font/icon sources, applies the font hooks and routes their main-menu entries. Current integrated verification results are in [PORT_STATUS.md](PORT_STATUS.md). The [chat appearance extension](#chat-appearance-extension) below is implemented separately and requires the listed parent integration edits.

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

## Chat appearance extension

`appearance_extension_patches.py` and three new Swift files implement **seven
switches plus a border-color preference**. This slice targets the pinned
`release-12.9.2` commit `6ad963e5b62d354da79040f388ae2b9132fb17b8`, including the
assembled public WhiteGram overlay. It has not been wired into the parent assembler
or capability catalog by this slice.

### Original keys and evidence

Evidence paths below are relative to
`C:\coding\telegram\whitegram\whitegram-rebuild`. These artifacts identify the
original fields, types, menu controls and native getter call sites. They do **not**
establish pixel-identical rendering, original defaults or final localized copy.

| Catalog row / order | Stored field (also mirrored as `wg_` + field) | Type | Implemented consumer |
| --- | --- | --- | --- |
| `messageBorder` / 135 | `messageBorderEnabled` | Bool | Native bubble outline, including merged corners and tails |
| Color field, no separately recovered catalog row | `messageBorderColorHex` | String | Validated `#RRGGBB` color; empty uses each direction's theme accent |
| `transparentMessages` / 136 | `transparentMessages` | Bool | Bubble fill, wallpaper/gradient backdrop and shadow opacity zero |
| `semiTransparentBubbles` / 137 | `semiTransparentBubbles` | Bool | The same background layers at 0.65 opacity |
| `showCharCountTyping` / 110 | `showCharCountTyping` | Bool | Composer count above the draft; native remaining-limit warning takes priority |
| `showCharCountMessages` / 111 | `showCharCountMessages` | Bool | Character count in text/caption date-and-status layout |
| `showActionTime` / 210 | `showActionTime` | Bool | Local event time appended to nonempty service-action labels |
| `hideBusinessBotPanel` / 105 | `hideBusinessBotPanel` | Bool | Excludes the managing-bot title panel while allowing later title-panel selection |

Specific evidence:

- `generated-settings/WhitegramSettingsState.swift`: fields/types at lines 62–64,
  77, 104, 112–113 and 153. The generated default values are clean-room choices.
- `generated-settings/WhitegramSettingsCatalog.swift` and
  `menu-cases-3.1.1/MENU_CASES.md`: recovered switch constructors. Native menu
  addresses: border `0xddd678`, transparent `0xdddbe0`, semi-transparent
  `0xde356c`, typing count `0xddd760`, message count `0xddcacc`, action time
  `0xde1d9c`.
- `recovered-3.1.1/WGRecoveredPreferenceKeys.swift`: exact `wg_` key spellings,
  including `wg_messageBorderEnabled` and `wg_messageBorderColorHex`.
- `recovered-3.1.1/native/TelegramUIFramework-0/types.json`: the recovered
  `WGMessagePreviewSnapshot` includes the three bubble Booleans and color String;
  `WhitegramSettingsState` contains the count, time and panel Booleans.
- `recovered-3.1.1/native/TelegramUIFramework-0/hooks.json`: border getter at
  `0x15dbbf0`, border-color getter at `0x15dbd00`, transparency getter at
  `0x15db9a8`, and the three flags read during
  `ChatMessageBubbleItemNode.animateContentFromTextInputField` at
  `0x15c47dc` / `0x15c47e4` / `0x15c47ec`. Message count is read at `0x16126c4`
  in the text-bubble layout cluster. Typing count is read at `0x27eaf04` inside
  `ChatTextInputPanelNode.chatInputTextNodeDidUpdateText` and at
  `0x27ecf8c` / `0x27ed18c` / `0x27ed310`. Action-time and business-panel getter
  calls are recorded at `0x1cb0914` and `0x235e98` respectively.
- `labels-3.1.1/labels.tsv`: `wh.messageBorder`, `wh.transparentMsgs`,
  `wh.semiTransparent`, `wh.charCountTyping` and `wh.charCountMsgs` identifiers.
  Their presence is not treated as a verified translation mapping.

The inspected public checkout's `WhiteGramSettingsController.swift`,
`BubbleSettings/BubbleSettingsController.swift` and chat-rendering interfaces were
used to check compatibility. This family's recovered keys are additional to the
public compact-list, tab, sticker, timestamp and wide-post implementation.

### Behavior and reconstruction boundaries

- **Shape-aware borders:** `WhitegramBubbleAppearance` uses Telegram's actual
  `messageBubbleImage(... shadow: ..., onlyOutline: true)` rasterizer and its
  native stroke width. All seven merge variants in each direction are covered,
  including `.Extracted`. The current radii and merge-corner setting are retained
  on `PrincipalThemeEssentialGraphics`; no rounded-rectangle approximation is used.
  A 128-entry `NSCache` keys outlines by direction, neighbor shape, effective
  radii, resolved RGB and screen scale. No new TelegramCore dependency is added
  to the lower-level `ChatMessageBackground` module.
- **Background-only opacity:** the fill image, original outline and shadow are
  faded; a custom enabled border stays opaque. Wallpaper/gradient content uses
  its own child opacity, so a node's send/selection animation can still animate
  its container. Mask images, message text and media are not made translucent.
  Highlighted background images remain visible; send-transition image layers
  use the selected fill opacity rather than flashing a solid fill.
- **Mode precedence:** transparent wins if imported data enables both flags.
  Enabling either switch on the new screen writes that flag and disables the
  other in one `WhitegramPreferences.update`. Disabling a switch changes only
  that flag. Border color is independent of both flags.
- **Count semantics:** Swift `String.count` counts extended grapheme clusters,
  including spaces/newlines. Counts use the original message text, before local
  translation or decoration. The timestamp/status path measures the extra text,
  preserving read/sent indicators and view/reaction layout. Restricted message
  bodies and sponsored labels are excluded. Captions are covered when rendered
  by `ChatMessageTextBubbleContentNode` with a status line; modes that suppress
  that line, media without a caption, polls and file-name labels do not gain a count.
- **Composer:** a 22-point row is reserved after any reply/accessory content and
  before the text field, including a single-line draft. Send/record/accessory
  buttons remain in their native bottom row. Counts refresh on text updates,
  including edits that do not change field height. Counts are suppressed while
  recording, displaying a recording draft, or with text entry disabled. An
  existing edit/business-link/custom text limit displays `count / limit` until
  fewer than five characters remain; then the original remaining count, red
  over-limit color and `-999` display cap take priority. Normal unlimited drafts
  display only their count; this does not change Telegram's sending limits.
- **Service time:** the suffix is a new plain attributed line in the service
  bubble's native primary text color. Existing attributed links are retained.
  It uses the message's timestamp and Telegram's date/time formatting; it does
  not represent a newly observed event or change the message timestamp.
- **Persistence:** the shared JSON snapshot takes precedence over an older raw
  `wg_` primitive on a per-key basis. Only actual Boolean values activate flags;
  a numeric `1` or a string does not. A saved false/empty value wins over a stale
  raw mirror. All writes, including reset, use the shared preference store and
  its existing notification. These seven switches default off. Reset touches
  only the eight fields in the table.
- **Invalid colors:** six ASCII hexadecimal digits, optionally prefixed `#`,
  are accepted and normalized to uppercase `#RRGGBB`. Empty selects automatic.
  Invalid edits show a visible error and preserve the saved value. An invalid
  imported string is preserved, reported on the screen, and rendered with the
  theme accent until corrected.
- **Live layout:** one disposable subscription per displayed `ChatControllerImpl`
  listens to distinct appearance snapshots on the main queue. It recreates
  `ChatPresentationData` with the existing theme, font, preview and animation
  fields and emits through the native history promise. The actual
  `ChatHistoryEntry` comparisons invalidate both individual and grouped messages
  on this identity change. The controller node also receives `forceLayout: true`
  for the composer/title panels. The subscription weakly captures its controller
  and is disposed in deinit.
- **Screen:** `whitegramAppearanceController(context:)` is a real
  `ItemListController` with seven switches, color editing, reset, errors, and a
  live `ThemeSettingsChatPreviewItem`. The preview uses native incoming/outgoing
  message items and current wallpaper. English/Russian copy, 65% opacity,
  automatic accent selection, the counter placement and suffix wording are
  reconstructed design decisions, not recovered exact implementation details.

`liquidGlassBubbles`, `glassMessageBubbles`, `lightChatUI`, new-header styling and
other shader/theme modes are not activated by this extension. Their saved fields
do not imply an implementation here. Actual device rendering and animations still
need the native validation described below.

### Required parent integration

1. Add these mappings to the parent assembler's source-copy table:

   ```python
   "cleanroom/WhitegramAppearanceSettings.swift": "submodules/TelegramCore/Sources/Settings/WhitegramAppearanceSettings.swift",
   "cleanroom/WhitegramBubbleAppearance.swift": "submodules/TelegramPresentationData/Sources/WhitegramBubbleAppearance.swift",
   "cleanroom/WhitegramAppearanceController.swift": "submodules/SettingsUI/Sources/WhitegramAppearanceController.swift",
   ```

   TelegramCore, TelegramPresentationData and SettingsUI already glob these
   directories and declare the imported project modules. The latter source
   needs to be in **SettingsUI**, alongside the internal native preview item.
   The renderer needs to be in **TelegramPresentationData**, where the graphics
   and bubble-rasterizer types are defined. Foundation/CoreFoundation/UIKit are
   SDK imports. No BUILD dependency change is required by this slice.

2. Import and run the additional patch pass after public API adaptation, while
   assembling a writable target tree:

   ```python
   from appearance_extension_patches import apply_appearance_extensions

   appearance_extension_features = apply_appearance_extensions(source_root)
   ```

   Keep the existing font `apply_appearance_patches` call as well. The new pass
   reports `bubble-presentation`, `showCharCountTyping`, `showCharCountMessages`,
   `showActionTime`, `hideBusinessBotPanel`, and `appearance-live-refresh` across
   eight native files. It stages every exact edit before writing and rejects
   missing, duplicate and mixed old/new anchors. Reapplying it produces no writes.

3. Route these original catalog rows through `WhitegramPortCapabilities.screens`:

   ```swift
   "messageBorder": "appearanceExtensions",
   "transparentMessages": "appearanceExtensions",
   "semiTransparentBubbles": "appearanceExtensions",
   "showCharCountTyping": "appearanceExtensions",
   "showCharCountMessages": "appearanceExtensions",
   "showActionTime": "appearanceExtensions",
   "hideBusinessBotPanel": "appearanceExtensions",
   ```

   Add this case to `WhitegramSettingsCoordinator.open` in the parent-owned
   `WhitegramGeneratedSettingsScreen.swift`:

   ```swift
   case "appearanceExtensions": target = whitegramAppearanceController(context: self.context)
   ```

   The existing Appearance category already opens catalog sections 3 and 9, so
   its newly supported bubble rows reach the complete screen; search/all-settings
   can reach it through every mapped row. Routing through the screen keeps color
   validation and paired transparency writes together. The original border row
   is `messageBorder`, whereas its stored Boolean is `messageBorderEnabled`.
   Do not introduce a persisted `messageBorder` Boolean. MainMenu, ForkBridge,
   Preferences and the generated original catalog need no edits for this route.

### Extension verification and native follow-up

```powershell
$env:WHITEGRAM_APPEARANCE_SOURCE = 'C:\Users\Pisun4ik\AppData\Local\Temp\opencode\whitegram-validate-12.9.2'
& 'C:\Users\Pisun4ik\AppData\Local\Temp\opencode\whitegram-check-env\Scripts\python.exe' -B -m unittest discover -s 'whitegram\tests' -p 'test_appearance_extensions.py' -v
```

**18 tests passed, none skipped.** Tests read both complete pristine files from
the pinned commit and the current assembled files, then patch only an in-memory
filesystem. They check exact reversal, all missing anchors (including late edits),
ambiguous/already-applied anchors, partial application, second-pass zero writes,
CRLF normalization, unrelated-file isolation, coexistence with another chat deinit
hook, all 14 outline variants, unchanged
masks/geometry/status arguments, recovered keys/types, and the native history
invalidation contract. Tree-sitter parses all three new Swift files and all eight
patched Swift files without errors. No test writes to either reference checkout.

AISLOP 0.13.1 scored the new Python patch module **100/100 with zero findings** in
a disposable, isolated copy. Its default scan excludes tests and does not support
Swift (three files reported unsupported), so that score is not a Swift quality or
typecheck result. The repository-wide scan also reported findings in other owners'
plugin/CLI files; it was not a whole-repository clean pass. No AISLOP rules or
configuration were changed.

This is **not a Swift typecheck or iOS build**. Swift/Xcode are unavailable on the
Windows host. Native compile risks concentrate in inferred ItemList/Signal generic
types and keeping the three files in their specified modules. The preview and
rasterizer signatures were checked against real 12.9.2 sources; no private UIKit
API or added framework is used.

Native validation should exercise light/dark/custom themes and solid/photo/gradient
wallpapers; both message directions, merged groups/tails, no-tail modes, long-press
extraction, highlight and send transitions; toggle/reset while a chat is open;
emoji/combining-character counts and translated/restricted captions; single-line,
reply, long, empty and near/over-limit drafts in portrait/landscape and iPad split
view; service labels with links; and business-bot/pinned-panel priority. In
particular, the composer row and glass backdrop alpha need visual/device checks,
and saved values need a termination/relaunch check after parent integration.
