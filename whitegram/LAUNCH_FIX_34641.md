# Launch crash and original primary icon

## Reported crash

The user-supplied IPS describes version 12.9.4, **build 34639**, re-signed with
bundle ID `test.telegra.Telegraph`, on iPhone OS 27.0.1. The process exits about
0.2 seconds after launch with an uncaught Objective-C exception (`SIGABRT`).
The exception stack enters CloudKit from TelegramCoreFramework and
SwiftSignalKit. Its CloudKit frames include offsets `0x101fc` and `0x361ec`;
the application caller is TelegramCoreFramework + `0xd3c9d8`.

The matching source path is the optional emergency datacenter provider:

`AppDelegate → BuildConfig.isICloudEnabled → NetworkInitializationArguments →
Network → CloudData.fetchRawData → CKContainer.default()`.

The build inherited `enable_icloud: true` while the distributed IPA has no
provisioned Telegram iCloud container. Calling the default container after
re-signing can throw an Objective-C exception that Swift signal error handling
does not catch. `configure.py` now sets `enable_icloud: false` for this unsigned
distribution. Existing MTProto seed addresses and the other backup-IP sources
remain active.

The IPS does not include the exception reason or entitlement values. Its Core
UUID (`e366d3d4-c5fd-38bf-adc2-630ea6b9c67e`) differs from the downloadable 3625798
artifact (`5afab277-42db-3cad-926a-77526fd5cd67`), despite the same build number;
offsets were therefore **not** symbolicated against that nonmatching binary.
The CloudKit failure is observed; missing container entitlements are the leading
source-supported diagnosis. Device confirmation of the fix remains required.

Regression tests execute the real configuration script and the upstream build
configuration generator, requiring `telegram_enable_icloud = False`.
CI also checks the configured flag before compilation.

## Icon recovery

The public checkout's primary `AppIconLLC` is the blue paper-plane icon. The
original WhiteGram 3.1.1 IPA instead declares `WGPrimary` and contains a black
WhiteGram mark on a white background. Its light, dark and tintable 1024×1024
rasters were recovered from the original CoreUI catalog's LZFSE chunks.

`resources/primary-icon/manifest.json` records the source IPA/catalog SHA-256,
each exact rendition offset, output PNG hash and decoded RGBA pixel hash.
Recovery does not redraw or enlarge the supplied artwork. All source rasters
are opaque; RGB PNG encoding retains every decoded pixel.

To reproduce in a Python 3.11 environment with Pillow 11.3.0 and lzfse 0.4.2:

```text
python whitegram/recover_primary_icon.py ORIGINAL.ipa NEW_OUTPUT_DIRECTORY
```

`primary_icon.py` installs these three variants as `WGPrimary.appiconset` in the
existing `DefaultAppIcon` build target. Configuring an already-configured tree
is supported. Tests verify decoded pixel hashes after installation, and IPA
validation requires the WGPrimary iPhone/iPad declarations and compiled PNGs.

These are the original static appearance rasters. Dynamic Icon Composer
layer/lighting behavior is not established by raster recovery. Final device
rendering and icon-cache refresh after re-signing remain to be checked.

## Build checkpoint

Build **34641**, revision `64ce8ab784bb21210133584cc52f8f8ec51c096a`, passed
[CI run 38742973871](https://github.com/HVHBIGNAME/ios-build-ci/actions/runs/38742973871)
on 2026-10-15. The initial icon compilation rejected unassigned legacy PNGs;
the follow-up commit removes those images and its regression test covers this.

The downloaded IPA passed local verification with both `--require-diagnostics`
and `--require-original-icon`: ZIP CRC, arm64 executable, all six extension IDs,
exact committed plugin SDK, diagnostics configuration/revision, and WGPrimary
primary-icon declarations for both iPhone and iPad.

- Artifact: `11979430165` (`WhiteGram-12.9.4-34641-unsigned`).
- Matching symbols: `11979930050`.
- IPA bytes: `75,541,066`.
- IPA SHA-256: `a7023bd975999b90f11ba54794860e24702b2bf02e76cf01447eb03622664153`.
- Local IPA: `C:\coding\telegram\whitegram\build-64ce8ab\WhiteGram.ipa`.

The existing diagnostic receiver was resumed with its original configuration;
public HTTPS health returned success. Successful compilation and archive checks
are not a verified launch on a physical device; user confirmation is pending.
The raw IPS and its device identifiers are not committed.

## Follow-up build 34642

The 2026-10-15 17:03:18 IPS was rechecked: it reports build 34639 and an
uncaught CloudKit exception. It does not establish a crash in build 34641.
The new build retains the disabled iCloud configuration and the recovered
WGPrimary appearance rasters. Source tests recheck configuration propagation
and the installed icon pixel hashes.

The build-34642 workflow now requires both original-icon and diagnostics checks.
Its IPA filename includes the version/build number to distinguish it from older
downloads. Native-build and device results must be recorded after completion.
