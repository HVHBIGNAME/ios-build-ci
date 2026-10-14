# Composer formatting and Return-key controls

The source baseline is still Telegram `release-12.9.2` (`6ad963e5`), with
12.9.4 / 34639 application metadata. The 3.2 / 13.0 IPA is reference evidence.

## Connected behavior

- Autoformat settings select off, bold, italic, monospace, strikethrough, spoiler,
  mixed script or uppercase mixed script. Selection updates all three stored keys
  atomically. Both outgoing text and media captions use the resulting entities.
- Existing code/preformatted ranges remain intact. Mixed script preserves URLs,
  mentions, commands, custom emoji and other address-bearing entities; uppercase
  never expands UTF-16 lengths. Display-only Zalgo filtering remaps entity bounds.
- The keyboard toolbar has delete, select all, speech, formatting/link/quote/code,
  clear-formatting and undo/redo actions. Native rich documents use editor commands;
  flat-only operations are disabled when flattening would lose structure. Buttons
  expose localized labels, availability and selected state with 44-point hit areas.
- `sendOnReturnKey` defaults to false. Plain Return can send when enabled;
  Shift-Return inserts a newline. The main composer's existing Cmd-Return option
  remains usable. Software Return respects selection replacement and marked text.
  Hardware-inserted newlines cannot re-enter the software-send callback.
- Both main input backends and attachment captions refresh their `.send`/`.default`
  keyboard trait after preference changes. The native editor's generic callbacks
  default to ordinary newline behavior in other hosts.
- Settings backup/import accepts the canonical and `wg_` Boolean key. New labels
  have ru/uk/en fallbacks and support custom localization overrides.

## Reference

3.2 IPA SHA-256:
`5cf287812de7707dd21256281e645c29a9a5c0da3f66910746254842fce5ffbf`.
Compact evidence is in `whitegram-rebuild/recovered-3.2/composer-resolved/`.
The Core getter at `0x21e8a4` establishes the false default; UI functions at
`0x2b47d10`, `0x2b4c620`, `0x269a5b4` and `0x2b2f434` cover hardware/software
Return, captions and keyboard traits. Import resolution includes chained fixups;
earlier incomplete call-site inventories are not used as absence evidence.

## Verification

Fresh-tree check on 2026-10-12: 594 public-overlay files applied without conflicts;
compatibility added 71 imports and 149 dependencies, then replayed with zero
additional imports/dependencies. The full source suite passed 276 tests, voice
integration 22, player integration 10, and JavaScript/plugin tests 51. All 450
changed/new Swift sources passed the baseline-relative syntax check. The separate
settings-transfer check parsed 38 XCTest methods; native execution is pending CI.

The Python regressions cover the pinned original and assembled sources, exact
installation, write-free replay, cross-patcher lifecycle composition, atomic
rejection of damaged/duplicate hooks, label availability and Swift syntax.
Foundation XCTest regressions cover Return policies, settings persistence,
localization overrides and Unicode range behavior. The existing native CI runner
includes these tests and the full app build. Revision `3625798` completed
[run 38337625690](https://github.com/HVHBIGNAME/ios-build-ci/actions/runs/38337625690)
on 2026-10-13: source validation, native suites, release compilation and verified
IPA upload all passed. This supersedes the pending-CI status in the Windows
checkpoint above.

Device checks still needed: both input engines, hardware and software keyboards,
IME confirmation, changing themes/languages, media captions, toolbar scrolling and
selection/undo on structured documents. Source checks alone do not certify these
interactions or exact visual parity with the reference client.
