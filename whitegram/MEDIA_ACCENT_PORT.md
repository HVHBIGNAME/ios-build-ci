# Neutral media accent

## Connected behavior

**Whitegram → Additional → Media without the theme accent** exposes the existing
`neutralMediaAccent` Boolean. The control is also available in settings search
and the full catalog. Its default is false; the existing `wg_neutralMediaAccent`
fallback, archive schema and ru/uk/en `s.neutralMediaAccent` label are retained.

When enabled:

- File/audio rendering takes its active control and title colors from the
  incoming or outgoing bubble's primary text color. This covers playback/download
  controls, voice waveforms, transcription shimmer, audio-level blobs and titles.
- The inactive waveform uses 40% of the text color's alpha, so progress remains
  distinguishable from the unplayed portion.
- Regular reaction pills inside bubbles use the corresponding bubble text color.
  Unselected/selected fills use 10%/25% alpha; media placeholders use 30%/60%.
  These opacity values are port design choices, not recovered original constants.
- Existing playback and streaming controls refresh both their background and
  foreground colors when the setting or theme changes.

`WhitegramMediaAccent.swift` creates per-render copies using the existing theme
`withUpdated` methods. Disabled calls return the original theme component.
The global theme and its cache are not mutated. Custom file tints retain their
existing precedence. Photo/album-art overlays, freeform reactions outside bubbles,
paid Stars reactions and extracted context-menu palettes retain their native
colors and contrast treatment.

The flag participates in `WhitegramAppearancePolicy` equality. The existing
`WhitegramAppearanceSettings.signal()` subscription therefore refreshes the open
chat's presentation data and re-renders media and reactions after a toggle or
settings import. No extra observer or player subscription is introduced.

## Integration

`media_accent_patches.py` patches:

- `ChatMessageInteractiveFileNode.swift`: layout and playback-status palettes;
  foreground recoloring for existing controls.
- `ChatMessageReactionsFooterContentNode.swift`: incoming/outgoing bubble pills.
- `ChatMessageDateAndStatusNode.swift`: inline bubble reactions.

`MEDIA_ACCENT_RUNTIME_FILES` installs the helper in TelegramPresentationData.
The existing consumer modules already import and depend on TelegramPresentationData
and TelegramCore. `compat-12.9.4.py` registers the helper and patch pass.

The recovered `s.neutralMediaAccent` / `wh.neutralMediaAccent` strings establish
the intended media surfaces and text-color behavior. Exact original rendering
parity has not been verified.

## Verification (Windows, 2026-10-14)

The full source suite passes **286 tests without skips**, using
`%TEMP%\opencode\whitegram-candidate-20261012-composer` and the matching public
checkout. It includes six new media-accent tests plus full installer composition
and replay with the earlier Wallet/Crypto Bot increment.

Checks cover pinned pristine and assembled inputs, baseline-relative Swift syntax,
exact patch reversal, write-free replay, atomic rejection of missing/duplicate
anchors, unchanged playback/download state selection and the native foreground
setter contract. The helper parses and is installed once at an unambiguous path.
The existing native appearance-policy suite now includes the flag's default,
Boolean typing, legacy fallback, explicit false precedence and refresh identity.
Those native assertions still require execution on macOS.

A new full app build and device checks remain pending. Verify incoming/outgoing
voice messages and music while playing, paused and downloading; toggle repeatedly;
switch light/dark/custom themes; compare selected/unselected reactions and imported
settings. The successful `3625798` IPA predates this increment.
