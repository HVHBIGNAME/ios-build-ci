# Original Whitegram stock launcher icons

These 66 PNGs are byte-for-byte copies from the original **3.1.1 / 12.9.2**
audit. In the inspected pinned public candidate, all 66 existing stock PNGs
differ in bytes, and eight (the Blue family) also differ in decoded pixel
identity. `manifest.json` records the original main-app `Info.plist`, audit
database and audit-manifest hashes, every source member/hash, dimensions and
premultiplied-RGBA fingerprint. Original encodings are retained (including CgBI
and the indexed `BlueFilledIconIpad.png`).

Reproduce from the build repository:

```text
python -B whitegram/recover_launcher_icons.py <audit-full-3.1.1> <output-directory>
```

The audit database is opened read-only. All source hashes are checked before
writing; an identical recovery is a no-write replay. Recovery verifies the
pinned manifest digest as well, so changing both a PNG and its audit row cannot
silently bless a replacement.

## Parent integration

```python
from launcher_icon_patches import (
    apply_launcher_icon_patches,
    install_launcher_icon_resources,
    verify_launcher_icon_bundle,
)

resource_report = install_launcher_icon_resources(target)
runtime_report = apply_launcher_icon_patches(target)
# After building, extract the IPA and pass the actual main .app:
packaging_report = verify_launcher_icon_bundle(app)
```

Both patchers return `SourcePatches`-style feature-to-path reports. Runtime uses
`showOriginalTelegramIcons`; resources use `showOriginalTelegramIcons-resources`.
The parent supplies this public TelegramCore API and its real Whitegram switch:

```swift
WhitegramIconSettings.current.showOriginalTelegramIcons // default false
WhitegramIconSettings.stockIcons // [(name: String, imageName: String)]
```

`stockIcons` must be exactly ordered:

```text
Blue/BlueIcon, New2/New2, New1/New1, Black/BlackIcon,
BlueClassic/BlueClassicIcon, BlackClassic/BlackClassicIcon,
BlueFilled/BlueFilledIcon, BlackFilled/BlackFilledIcon
```

The AppDelegate getter appends this array only under that Whitegram preference.
Every appended `PresentationAppIcon` explicitly has `isDefault: false` and
`isPremium: false`. Default plus all thirteen public WG alternatives remain in
their original order. `appearance_details_patches` may run before or after this
patch, including on repeated passes; its `WhitegramPrimaryPreview` is preserved.
Changing the switch does not itself change the currently selected launcher icon.

## Bazel and physical names

The installer creates
`Telegram/WhitegramStockLauncherIcons/<selection-name>.alticon/<original-file>`
and eight explicit `WhitegramStockLauncherIcon_<selection-name>` filegroups.
Only the main `ios_application(name = "Telegram")` gets those groups appended
to `alternate_icons`. Existing `alternate_icon_folders`, `.alticon` source
assets, primary icon catalogs, and source plists are untouched.

The selected source pins `rules_apple` at
`1791d916de4083388f22e20248d8b010d23f0d6b`:

- `apple/internal/resources.bzl` buckets `.alticon` paths as asset catalogs.
- `apple/internal/partials/support/resources_support.bzl` processes the PNGs
  and bundles their basenames at the application's resource root.
- `apple/internal/resource_actions/actool.bzl` invokes
  `tools/alticonstool/alticonstool.py` after the primary catalog is compiled.
- That tool names selections from the `.alticon` directory and derives
  `CFBundleIconFiles` from the actual basenames (removing `@2x`/`@3x` and `.png`).
  It writes the same union to `CFBundleIcons` and `CFBundleIcons~ipad`, retaining
  the primary entries. All WG groups must stay in `alternate_icons` because the
  tool replaces the alternate dictionary. An additional plist fragment alone
  would not survive this stage.

Thus `Blue.alticon` creates selection **Blue**, not **BlueIcon**. It contains
`BlueIcon@2x.png`, `BlueIcon@3x.png`, `BlueIconIpad.png`,
`BlueIconIpad@2x.png`, `BlueIconLargeIpad@2x.png` and the three original
notification PNGs. Black and both Classic families follow the same convention;
the two Filled families contain the five original launcher PNGs without a
notification family. All provide 120/180px phone and 76/152/167px iPad images.

### New1/New2 metadata repair

The original plist lists twelve `_WxH` stems for each icon, but most of those
files do not exist. The actual dimension-to-file mapping is:

| Pixels | New1 original file | New2 original file |
|---|---|---|
| 20 | `New1_notification.png` | `New2_notification.png` |
| 29 | `New1_29x29.png` | `New2-Small.png` |
| 40 | `New1_notification@2x.png` | `New2-Small-40.png` |
| 58 | `New1_58x58.png` | `New2-Small@2x.png` |
| 60 | `New1_notification@3x.png` | `New2_notification@3x.png` |
| 76 | `New1-76.png` | `New2-76.png` |
| 80 | `New1_80x80.png` | `New2-Small-40@2x.png` |
| 87 | `New1_87x87.png` | `New2-Small@3x.png` |
| 120 | `New1@2x.png` | `New2@2x.png` |
| 152 | `New1-76@2x.png` | `New2-76@2x.png` |
| 167 | `New1-83.5@2x.png` | `New2-83.5@2x.png` |
| 180 | `New1@3x.png` | `New2@3x.png` |

There is **no original `New2_notification@2x.png`**; the 40px file is
`New2-Small-40.png`. No PNG is renamed, generated or substituted. The new plist
references therefore come from these real filenames, not the broken metadata:

- New1: `New1`, `New1-76`, `New1-83.5`, `New1_29x29`, `New1_58x58`,
  `New1_80x80`, `New1_87x87`, `New1_notification`.
- New2: `New2`, `New2-76`, `New2-83.5`, `New2-Small`, `New2-Small-40`,
  `New2_notification`.

The exact table for all eight selections is also exported by
`stock_alternate_icon_entries()`. Preview names remain the original names;
`ThemeSettingsAppIconItem` loads them from `getAppBundle()` (the main app).

## Required packaging checks

`verify_launcher_icon_bundle()` requires `WGPrimary` for both device families,
all thirteen WG alternatives, all eight stock selections with the exact
filename-derived references, and all 66 recovered PNGs physically at the main
bundle root. Every alternate reference, including WG references, must resolve.
Byte changes from Xcode PNG processing are accepted only when dimensions and
decoded premultiplied RGBA pixels agree. Pass `baseline_info=<prior built
Info.plist dict>` to additionally require exact preservation of primary and
non-stock alternate declarations.

The resource-local `.gitattributes` keeps the pinned manifest at LF and the
PNGs binary across Windows and macOS checkouts.

Python tests can use `WHITEGRAM_ASSEMBLED_SOURCE` for the pinned candidate and
`WHITEGRAM_ORIGINAL_AUDIT` for original recovery. Set `WHITEGRAM_ALTICON_TOOL`
to the pinned tool's Python file to exercise its actual plist generation.
Its SHA-256 is
`831d2b43bfadd8f250e5208b2d8e11132fd85c6b571af430af65291b81d2b8fb`.
These are source/resource/packaging-tool checks. A newly built IPA and an iOS
selection/relaunch check remain the parent's final native verification.

### Verified handoff

All **17 tests passed, no skips**, against
`%TEMP%/opencode/whitegram-candidate-20261012-composer`, whose HEAD is
`6ad963e5b62d354da79040f388ae2b9132fb17b8`, with the original audit and the
hash-verified pinned `alticonstool` supplied. The suite exercised both appearance
patch orders and replays, full-AppDelegate baseline-relative Swift parsing,
original recovery and tamper rejection, primary catalog and existing `.alticon`
preservation, and the real tool's 21-entry phone/iPad tables. Bundle-verifier
tests used temporary fixture bundles assembled from those resource inputs.

```text
python -B -m unittest discover -s whitegram/tests -p test_launcher_icon_patches.py -v
```
