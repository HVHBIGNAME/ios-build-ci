# Native build verification — 2026-10-03

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
