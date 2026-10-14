# Profile appearance increment

`hideGifts` removes the Gifts pane from the computed visible pane list while
retaining the original pane list and gift contexts. Existing appearance updates
refresh the screen. The pane container repairs an initial/pending Gifts selection
when the tab is hidden, including a gifts-only profile. Turning the switch off
restores the server-provided tab order.

`visualUsernameEnabled` and `visualUsernameButton` connect a local editor and
profile/header display override for the current account only. Empty or invalid
overrides fall back to the real username. The editor accepts one optional `@`,
then 1–32 ASCII username characters starting with a letter. These validation
rules are port choices. Native username opening, QR codes and context actions
remain bound to the real Telegram account; no username-update RPC is issued.
When a different display name is active, additional real aliases are suppressed
in the profile row. Channel/group and other-user names retain their native data.

The existing preference store, legacy `wg_` fallback and archive schema are used.
The text participates in appearance snapshot equality, so changing just the text
also refreshes open profiles. Controls are available in settings search/the full
catalog; the visual username editor is also under Additional.

Local checks: five focused source tests and five full-installer composition tests
pass. Native appearance tests now cover normalization and text-change invalidation.
Full compilation and device verification require the build containing this increment.

Remaining device checks: own/other profiles, accounts with no real username,
toggle/edit/import/reset, username and QR actions, opening a hidden Gifts deep
link, hiding the active tab and restoring the original tab order.
