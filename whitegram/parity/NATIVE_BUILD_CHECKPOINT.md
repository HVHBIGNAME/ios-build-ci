# Native build verification — 2026-10-04

The twelfth integrated run completed the full release build and produced a locally verified IPA. See the final section for the artifact, revision and checksum. Device validation remains outstanding.

## Initial integrated run

- Commit: `91fc3eb444deb155220fbeabb98ded47eec90fee`.
- Run: https://github.com/HVHBIGNAME/ios-build-ci/actions/runs/37092453068.
- macOS completed source checkout, public overlay, compatibility assembly and all source/plugin checks.
- Native service, plugin, history, settings-transfer, translation, privacy, account, appearance, media and player suites passed.
- Native localization, backend and voice suites stopped at compilation. The IPA build was not reached.

The reported compilation failures were:

1. `WhitegramSettingsState` needed an explicit public zero-argument initializer for the SettingsUI module.
2. The nested profile-fetch callback required explicit `self` for its session/cache properties.
3. The empty audio-buffer test needed an `Int16` element type after the new Float overload was introduced.

These are addressed in the follow-up commit; its native results must be checked separately. No device or authenticated-service pass is implied.

## Second integrated run

- Commit: `a534d9d10b889edfb4902004389f58380d74a81a`.
- Run: https://github.com/HVHBIGNAME/ios-build-ci/actions/runs/37093619445.
- Source integration and the native localization suite passed; the initial compilation failures were resolved.
- The backend suite executed 38 tests with three assertion failures in two cases: a CRLF-containing session token was accepted, and a profile entity splitting an emoji's UTF-16 surrogate pair was accepted by both the range validator and response decoder.
- The voice DSP executable compiled, then exited with `SIGTRAP` without an assertion message. Its buffered output did not identify the failing group, and the voice protocol executable was not reached.
- All other scheduled native suites passed. The IPA build was not reached.

The next revision checks session-token line breaks as UTF-8 bytes and profile entity boundaries as UTF-16 scalar boundaries. Regression cases cover CR, LF, CRLF, both halves of a surrogate pair, combining scalars and overflowing ranges. Voice test executables now report each group and caught failure immediately; both DSP and protocol executables run before their combined failure status is returned.

Local follow-up checks: 14 backend source/evidence/composition tests and 22 voice source/adapter tests passed. Native confirmation remains pending in CI.

## Third integrated run

- Commit: `b3dd6f37fb31885543df5ef550b4beec57bac300`.
- Run: https://github.com/HVHBIGNAME/ios-build-ci/actions/runs/37095028960.
- All 38 backend XCTest cases passed, including expanded token and entity regressions.
- Voice protocol checks compiled and all four groups passed.
- Voice DSP passed its first eight groups, then terminated inside the fixed-duration pitch-frequency test before reaching a catchable assertion. The remaining DSP groups were not reached.
- Every other scheduled native suite and source validation passed. The IPA build was not reached.

The pitch reader added the ring length to a negative floating-point position before converting it to an array index. At -12 semitones, frame 7776 produces position `-4.547473508864641e-13`; adding the 4320-sample ring length rounds to exactly `4320`, outside the array. The follow-up wraps the integer index after separating its fractional component. The existing 72000-sample octave-down test exercises this boundary; native confirmation is pending.

## Fourth integrated run

- Commit: `58f857db0becc7ac687123a30c580c7ffb70c18c`.
- Run: https://github.com/HVHBIGNAME/ios-build-ci/actions/runs/37095904673.
- The pitch reader no longer trapped. All 15 DSP groups ran: 14 passed and the fixed-duration pitch test reported insufficient energy at exactly 250 Hz for the octave-down case.
- All four voice protocol groups and all other scheduled native suites passed. Source validation passed; the IPA build was not reached.

The remaining assertion was checked against original Core `0x2d6d48...0x2d7044`: its triangular two-head delay sweep produces a comb of neighboring spectral lines. The follow-up measures the strongest bin within the head-sweep frequency of the target, using the recovered delay span to bound the search. It still requires shifted power above `0.005`, suppression of the original fundamental by a factor of 30, and fixed output duration. Native confirmation is pending.

## Fifth integrated run: native gate passed

- Commit: `1bafbf9b2002a268ad43d175a9e9efbfca2a8bea`.
- Run: https://github.com/HVHBIGNAME/ios-build-ci/actions/runs/37096789202.
- Source validation and every scheduled native Swift suite passed, including all 15 DSP and four voice protocol groups.
- Release IPA compilation reached Bazel analysis, which rejected `TelegramCore/BUILD`: the dependency installer appended a new label after a final item without adding a separating comma.
- A new assembled-BUILD token check reproduced this failure and found the same issue in `GiftItemComponent/BUILD` before Bazel reached it.

The follow-up prepends a comma-terminated dependency instead of relying on a trailing comma in upstream lists. Tests exercise empty lists, optional commas, comments, shorthand labels, replay and all modified assembled BUILD files. The release build now uses `--continueOnError` to collect failures from independent Bazel targets in one pass; build failures still return a nonzero status.

Local follow-up: compatibility replay and all 219 top-level Python tests passed. The scanner reported only the three existing CLI progress `print()` calls in `compat-12.9.4.py`; these are intentional command output, not debug logging. Swift remains outside that scanner's coverage.

## Sixth integrated run: TelegramCore integration

- Commit: `28cc236f8c0a9cde24ad44060511312dfd8a5b0d`.
- Run: https://github.com/HVHBIGNAME/ios-build-ci/actions/runs/37098034833.
- Source checks, native suites and Bazel analysis passed. Release compilation reached TelegramCore and reported two API integration errors.
- `MTRpcError.errorDescription` is an Objective-C implicitly unwrapped optional; assigning it to a local inferred `String?`, which cannot be used for migration-prefix parsing without unwrapping.
- Pinned `messages.readSavedHistory` requires `parentPeer: Api.InputPeer`, not an optional parent.

The follow-up rejects missing RPC descriptions as `.network` and accepts optional descriptions in the shared authorization-error mapper, with nil/empty regression cases. Read actions use the existing `apiInputPeerOrSelf(_:accountPeerId:)` helper and pass its concrete parent to `readSavedHistory`, covering Saved Messages without requiring a self access hash. Full application compilation remains the integration check for these adapters.

## Seventh integrated run: framework linking and history rendering

- Commit: `679b90b69495e0246cb05dc66e4f74f4439867d5`.
- Run: https://github.com/HVHBIGNAME/ios-build-ci/actions/runs/37121455210.
- All validation suites passed and TelegramCore compiled. The full build collected two remaining failures before reaching application packaging.
- TelegramCoreFramework linked LegacyComponents through AudioWaveform's unused AsyncDisplayKit/Display/LegacyComponents dependencies, introducing unresolved `AVCaptureEventInteraction` and `MPVolumeView` symbols. The pinned AudioWaveform target's sole Swift source imports only Foundation.
- The inline original-message renderer called `validatedEntityRange`, which does not exist in the pinned source tree.

The follow-up removes AudioWaveform's unused UI dependencies and verifies its Foundation-only source contract. History rendering uses the existing public UTF-16 scalar-boundary validator before formatting and before applying custom-emoji attributes. The installer upgrades the previously emitted history block on replay instead of inserting a duplicate.

## Eighth integrated run: SettingsUI compilation

- Commit: `15c8dd5f57470de3213885e7ed4e33dcd9d411f8`.
- Run: https://github.com/HVHBIGNAME/ios-build-ci/actions/runs/37123992036.
- Source checks and every scheduled native suite passed. The previous framework-linking and inline-history errors were resolved; release compilation reached SettingsUI.
- The plugin startup path passes a `UIViewController`, while the runtime's forwarding method unnecessarily required `Display.ViewController` even though the UI adapter accepts either a navigation controller or a screen.
- API-status and radio row helpers placed an unlabeled default section before the required content. Two-argument calls were therefore interpreted as passing content to an `Int32` parameter.
- The generic account-save worker needed an explicit optional-error tuple result. Nested radio and profile-wall closures needed explicit `self` references.
- Local photo-wall loading used `FileHandle.read(upToCount:)`, which requires iOS 13.4; the app targets iOS 13.0.

The follow-up accepts `UIViewController` in the runtime attachment method, uses a trailing labeled section argument, types the account-save result and qualifies the nested captures. Photo-wall loading uses bounded `InputStream` chunks with read-error propagation, the existing 8 MiB limit and JPEG-prefix validation. New native cases exercise the exact size limit, oversized and malformed files, symbolic links and directories.

Local follow-up: compatibility replay and all 220 top-level Python tests passed. The scanner reported zero findings in its supported files; Swift is outside its coverage. Native confirmation and full IPA packaging remain pending in the next CI run.

## Ninth integrated run: optimized streak-service lifetime

- Commit: `dc765c1dd643446bc32e824a34981b04e8840575`.
- Run: https://github.com/HVHBIGNAME/ios-build-ci/actions/runs/37172286916.
- Source checks and all native suites passed, including the new wallpaper boundary and file-type cases. The eighth run's SettingsUI diagnostics were resolved.
- Release optimization found one further SettingsUI error: `setEnabled` created a temporary `WhitegramProfileService`, whose weak response capture is always nil after the call returns. This also prevented successful streak-setting changes from publishing the profile-update notification.

The streak service now owns its profile service for the account session's lifetime. A regression test delivers delayed failed and successful settings responses and checks that only success publishes the account-specific update. Full release-build confirmation remains pending.

## Tenth integrated run: TelegramUI logout-patch cleanup

- Commit: `971359cafb8aa041c168fefc2e101c3df37a901a`.
- Run: https://github.com/HVHBIGNAME/ios-build-ci/actions/runs/37173350350.
- All source/native validation passed, including the streak mutation-notification test. SettingsUI compiled and linked, followed by PeerInfoScreen and the other immediate consumers.
- TelegramUI compilation stopped at an unused `accountId` in `ApplicationContext`. The retention installer already requested its removal, but `SourcePatches.replace` saw the shorter replacement inside the original anchor and incorrectly treated the deletion as installed.

The replacement helper now applies shortening edits while their original fragment remains and rejects mixed old/new fragments. Regression tests first reproduced the skipped removal and ambiguous mixed-state acceptance, then passed with the fix. They also cover repeated anchors and insertion replay; account integration explicitly checks the obsolete logout variable is removed. Compatibility replay and all 224 top-level Python tests passed locally, with zero scanner findings in supported files. Full release-build confirmation remains pending.

## Eleventh integrated run: Opus symbols across framework boundaries

- Commit: `9c99f6b061b3abe4e810075732b48c64541a8262`.
- Run: https://github.com/HVHBIGNAME/ios-build-ci/actions/runs/37174950270.
- Source checks and every native suite passed. TelegramUI compiled, and the build reached TelegramUIFramework linking.
- WebRTC referenced four missing Opus functions: `opus_multistream_encode`, `opus_multistream_encoder_create`, `opus_multistream_encoder_ctl` and `opus_multistream_encoder_destroy`.
- Voice processing now brings OpusBinding and its static Opus archive into TelegramCoreFramework. Bazel excludes that archive from the dependent TelegramUIFramework link, while the Core link loads only the archive members it uses. The multistream encoder is used by WebRTC in UI, not by Core.

The follow-up imports the existing Opus archive through `cc_import(alwayslink=True)` so Core links the complete codec. Bazel 8.4.2's `cc_library` implementation does not apply its `alwayslink` attribute to precompiled `.a` inputs; `cc_import` does. The assembled-BUILD check requires this import contract. The Opus build and its public dependency labels remain the same. Native framework-link confirmation is pending.

## Twelfth integrated run: release IPA verified

- Commit: `5bda12ad897d35f73047acaf7249418769b2ae01`.
- Run: https://github.com/HVHBIGNAME/ios-build-ci/actions/runs/37176472659 — **success**, 13m31s.
- All source/native checks, full release compilation, framework linking, packaging and IPA upload passed. The source report checked 410 Swift files without new parser diagnostics; the local top-level Python suite passed 225 tests.
- Artifact: [WhiteGram-12.9.4-34639-unsigned](https://github.com/HVHBIGNAME/ios-build-ci/actions/runs/37176472659/artifacts/11293782721), containing `WhiteGram.ipa` and `WhiteGram-verification.json`.
- IPA size: **74,637,478 bytes**. SHA-256: `ed1f1b1ee4eb2a5b1faac89fba4b492920fed5633033d36e3e4278bc8dd42f7b`.
- Identity: `whitegram.telegra.Telegraph`, version `12.9.4`, build `34639`, arm64.

The artifact was downloaded under `recovery_20261002/build-37176472659/` and verified again with `whitegram/verify_ipa.py` against the exact committed revision. The local and CI reports match apart from the local file path. ZIP integrity, all six extension identities, 13 alternate icons and the exact bytes of all six plugin SDK scripts passed.

A separate local check confirmed a canonical 32-byte backend application key in the main app, no copied key in extension plists, and no stale signing-profile files or signature directories. No key values were printed or added to the report.

This is an unsigned device IPA requiring signing for installation. On-device launch, authenticated-service behavior and complete original-app parity have not been validated by this build.
