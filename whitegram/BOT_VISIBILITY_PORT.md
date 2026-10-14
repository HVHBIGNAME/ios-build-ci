# Wallet and Crypto Bot visibility

## Connected behavior

Both controls are available under **Whitegram → Menu sections**, settings search
and the full catalog. The existing ru/uk/en labels, Boolean defaults (false),
canonical preferences, `wg_` legacy fallback and settings archive schema are used.

- `hideWallet` now exposes the existing `appearance_parity_patches.py` consumer.
  It hides the Wallet mini-app row in Telegram Settings. Turning it off restores
  the row when the server supplies it; native activation and opening stay intact.
- `hideCryptoBot` filters the main Contacts list before sorting, alphabetical
  section construction and empty-state calculation. A peer must be a bot with
  the exact case-insensitive `cryptobot` username, using its legacy username or
  an active username alias. Display names and inactive aliases are not matched.
  The contact and its chat remain stored, and search can still find the bot.

`contact_visibility_patches.py` adds an opt-in initializer argument, enabled only
by `ContactsControllerNode`. Recipient/group-invitation selectors retain the
default false value, and the search branch is unchanged. The main Contacts host
uses no top-peer suggestions. Both name and presence sort modes share the filter.

The contacts subscription combines the contact snapshot with a distinct Boolean
preference signal, so toggling or importing the setting rebuilds visible entries
without waiting for a server update. Each queued transition captures its own
Boolean value. The existing disposable owns the observer lifetime. Wallet uses
the already-installed profile/settings appearance refresh subscription.

## Evidence and scope

The catalog supplies `hideWallet` / `hideCryptoBot` at orders 62 / 63. The recovered
`s.hideWallet`, `s.hideCryptoBot` and `wh.hideCryptoBot` strings establish the
surfaces, including Crypto Bot's Contacts-only description. The preference
inventory records `wg_hideCryptoBot`. Username matching and the opt-in integration
are port implementation choices; exact original identity matching has not been
established by instruction-level comparison.

## Verification (2026-10-14, Windows)

- 280 Python source/integration tests passed, with no skips, on the assembled
  `whitegram-candidate-20261012-composer` tree. This includes full installer-order
  composition/replay, baseline-relative Swift parsing, existing Wallet checks
  and four new Contacts integration tests.
- The Contacts tests also pass against the pinned pristine Telegram sources and
  the older local `source-12.9.2` tree. They cover search/selector isolation,
  subscription ownership, write-free replay and atomic rejection of drifted or
  duplicate anchors.
- Foundation policy regressions cover disabled/non-bot/lookalike cases, mixed-case
  usernames, legacy preferences, explicit false precedence and refresh identity.
  Their source parses; native execution is pending the existing macOS CI runner.

For the full suite, use the assembled tree in
`%TEMP%\opencode\whitegram-candidate-20261012-composer` and public checkout in
`%TEMP%\opencode\whitegram-public-20261012-composer` with the environment variables
documented in [PORT_STATUS.md](PORT_STATUS.md#repeating-local-checks).
The older `source-12.9.2` working copy lacks previously committed AudioWaveform
and Opus BUILD fixes; an initial full run there failed those two checks.

This increment still needs a native app build and device checks: toggle both
options, switch contact sort modes, search for Crypto Bot, open recipient
selection, relaunch, and restore a settings backup. The successful `3625798`
artifact predates this increment.
