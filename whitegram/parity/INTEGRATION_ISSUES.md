# Integration checkpoint and remaining issues

## Audio and privacy recording header — resolved at source level

The recording header previously conflicted between `voice_patches._patch_postprocessing` and `content_control_patches.retained_media_patches` for record-once behavior.

Both owners have decoupled their anchors. The parent's complete staged-order and Swift syntax tests now pass; their own two-order regressions cover the recording interaction. Native compilation is still required.

The regressions exercise both application orders using the actual transformations.

## Complete installer replay — resolved at source level

A fresh candidate assembled successfully, but replay initially failed on upgraded per-chat receipt wrappers. It also exposed overlapping account/plugin request anchors and duplicated startup initialization. The base stages now recognize their explicit later forms; account hooks use stable request/error-body anchors. Complete-sequence replay and mixed/duplicate-receipt rejection are covered in `tests/test_full_composition.py`. Both account/plugin orders are covered in `tests/test_account_patches.py`.

## Runtime installation

The installer includes appearance/history/accounts/content/media/player/voice/services/backend/traffic manifests and entrypoints. The current whole-installer test verifies that every clean-room Swift file is mapped and that destinations are unique, including on case-insensitive filesystems.

Service runtime files retain `submodules/SettingsUI/Sources/Whitegram/` in the installer to avoid leaving duplicate legacy source declarations when upgrading a previous assembly.

## Parent schema and compilation

Read COORDINATION.md for the parent's new numeric migrations and archive rules. The settings-transfer runner now includes real `WhitegramMediaSettings.swift` because the bridge uses its migration-aware initial-camera selection. New source checks passed; macOS XCTest and full iOS compilation are pending.

Player source tests require `WHITEGRAM_PLAYER_SOURCE`, now supplied by CI. The native player and backend runners are also scheduled. Tests for privacy, account retention, transfer and icon packs now distinguish pinned pre-patch fixtures from a fully installed tree; corruption fixtures actually remove a present anchor in either state.

## Remaining integration and parity work

- Services need account-bound adapters for the backend's new signed provider transport, including SSE, upload cancellation and preserved error responses. Direct-only clients and explicit proxy rejection remain a documented gap.
- Original notification/keepalive/RAM producers, exact menu row bindings/conditions and several appearance/profile/tracking/plugin features remain incomplete. The historical row inventory records these scopes, but its older failure counts are superseded by the parent checks.
- Original `customSettingsIcons` and `showOriginalTelegramIcons` controls have distinct semantics and are not implemented by opening an icon-pack manager. Their catalog rows remain present without that incorrect supported route.
- Native Swift/XCTest, the full IPA build, device interactions and authenticated historical services still need their own verification. Successful assembly/parser tests do not establish full-client parity.

## Static quality checks

`aislop scan --changes --json` cannot score the dominant Swift sources. Its `security/new-function` finding is in the approved-plugin CommonJS loader: source comes from the bounded, package-relative native resolver and is executed in that plugin's JavaScriptCore context. Dynamic execution is required for user-installed JavaScript modules; replacing `new Function` with an equivalent hidden evaluator would not improve the boundary. The JavaScript suite covers canonical module paths, parent/absolute path rejection, lifecycle and permission checks. This conservative finding is retained rather than suppressed.

Remaining nonfixable warnings concern the large plugin bootstrap/content-patch files, the public privacy-entrypoint wrapper and CLI progress output. Splitting the active worker modules is a separate maintenance change. No scanner rules or configuration were changed.
