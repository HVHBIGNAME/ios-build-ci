# Parent integration checkpoint — 2026-10-03

This checkpoint verifies source assembly and offline contracts. It does not certify full original-client parity or an iOS build.

## Candidate

- Editable overlay: `C:/coding/telegram/whitegram/ios-build-ci`.
- Fresh candidate: `C:/coding/telegram/whitegram/recovery_20261002/candidate-12.9.2`.
- Telegram pin: `6ad963e5b62d354da79040f388ae2b9132fb17b8` (`release-12.9.2`).
- Public overlay pin: `db18308774f863074278feedc4df4507b0fb174e`, based on `release-12.6.2`.
- The candidate is separate from the shared read-only assembled reference at `C:/coding/telegram/whitegram/source-12.9.2`.
- `configure.py` completed for app metadata 12.9.4. The source baseline is still 12.9.2.

## Repairs in this continuation

- Completed the history/plugin fixture with the real network and root-controller sources.
- Fixed complete-installer replay after per-chat privacy, live ad controls and startup hooks upgrade earlier stages. Explicit known upgraded forms are validated without restoring older guards. Mixed/duplicate receipt hooks remain errors.
- Made account authorization-failure hooks compose with plugin interception in both orders, using stable request/error-body anchors and preserving the emitted behavior.
- Corrected tests that assumed an already-patched tree must write every file again. Corruption and reversibility fixtures now use actual pinned pre-patch source, including the public Settings-icon delta.
- Fixed the optional-cast parsing ambiguity in `WhitegramForkBridge`.
- Connected history catalog actions to their exact native action cases and restored the main app-icon selector route. Icon-pack selection no longer claims to implement unrelated original icon-mode switches.
- Applied recovered absent-value defaults for AI provider/models, deleted-message opacity and particle speed/density; registered the additional service Boolean preferences for settings transfer.
- Set `WHITEGRAM_PLAYER_SOURCE` in CI and scheduled native player and backend suites. The previously skipped nine player source checks now execute.
- Removed the production application-signing key from committed code and fixtures. The packaging step obtains it from a repository Actions secret, and offline signing tests use a synthetic key. Missing/malformed configuration fails explicitly before a backend request or payload mutation.

## Observed verification

| Check | Result |
| --- | --- |
| Public overlay on fresh pinned source | 594 files applied; no unresolved conflicts |
| Compatibility assembly | Passed; 71 imports and 145 BUILD dependencies added on the initial pass |
| Compatibility replay | Passed; zero further compatibility imports/dependencies |
| Top-level Python integration suite against the complete candidate | 216 passed, no skips |
| Voice Python suite against the complete candidate | 22 passed, no skips |
| Player Python suite against the complete candidate | 10 passed, no skips |
| JavaScript SDK/bootstrap/hooks | 51 passed, no skips |
| Full Swift syntax comparison | 409 files; zero new parser diagnostics |
| Plugin Swift parser | 18 source/test files passed |
| Plugin/history hook contracts | 24 callsites in nine files; both tested orders and replay passed |
| Services parser/contracts | 17 production + eight test files passed; 83 XCTest methods supplied, not run |
| Settings-transfer parser/contracts | 10 production + three test files passed; 36 XCTest methods supplied, not run |
| Tracked patch whitespace | `git diff --check` passed |

Candidate reports are `whitegram-port-report.json`, `whitegram-runtime-report.json` and `whitegram-syntax-report.json` in the candidate root. Test counts describe this checkpoint, not future edits by other workers.

For local integration checks set `WHITEGRAM_ASSEMBLED_SOURCE`, `WHITEGRAM_APPEARANCE_SOURCE`, `WHITEGRAM_VOICE_SOURCE` and `WHITEGRAM_PLAYER_SOURCE` to the candidate. Set `WHITEGRAM_PUBLIC_SOURCE` and `WHITEGRAM_VOICE_PUBLIC_SOURCE` to `C:/coding/telegram/whitegram/whitegram-public`. Use the Python environment at `C:/coding/telegram/whitegram/whitegram-check-env/Scripts/python.exe` and the commands in `PORT_STATUS.md` plus `python -B -m unittest discover -s whitegram/tests/player -p 'test_*.py'`.

## Outstanding verification and implementation

Swift/Xcode are unavailable on this Windows host. Native XCTest, full IPA compilation, device behavior and authenticated external services have not been verified for this working tree. No new IPA was produced in this continuation.

The existing GitHub CI repository is **public**: `HVHBIGNAME/ios-build-ci`; the working branch is `whitegram-source-12.9.4`. The user explicitly approved committing/pushing these changes and running CI. This local checkpoint precedes that native build.

Implementation gaps include the account-bound provider-proxy adapters, notification/background/RAM consumers, remaining original menu bindings/conditions, and further appearance/profile/tracking/plugin behavior. See `INTEGRATION_ISSUES.md` and the hash-qualified historical inventory; older inventory test-failure counts are not the results above.

The quality scanner cannot score Swift. Its intentional CommonJS `new Function` loader finding and nonfixable size/wrapper/CLI-output warnings remain documented in `INTEGRATION_ISSUES.md`; no rules were disabled.
