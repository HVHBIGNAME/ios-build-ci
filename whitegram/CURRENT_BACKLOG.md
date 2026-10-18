# Remaining Whitegram implementation work

Updated 2026-10-18 after the profile-metadata, feedback and original-icons source increment.
**The client is not feature-complete.** The recovered catalog still
has **45 rows without UI routes**, including previews and informational text.
This is a routing count, not a percentage of implemented behavior. Reachable
screens also require behavioral/parity validation; the original 333-row audit in
`FEATURE_COVERAGE.md` is historical and cannot be used as current completion data.

## Unconnected catalog rows

### Previews (2)
- [ ] `chatListPreview`
- [ ] `tabBarPreview`

### Appearance/layout (10)
- [ ] `profileCoverPhoto`
- [ ] `resetProfileCoverPhoto`
- [ ] `videoChatBackground`
- [ ] `resetVideoBackground`
- [ ] `videoBackgroundInProfile`
- [ ] `newChatListUI`
- [ ] `newChatHeaderStyle`
- [ ] `classicInterface` — existing glass suppression is not the whole classic layout
- [ ] `oledMode`
- [ ] `reactionButtonGlow`

### Navigation/account presentation (6)
- [ ] `hideSettingsReorderAccounts`
- [ ] `showPostsFeed`
- [ ] `separateProfileTab`
- [ ] `hideBottomTabBar` — a compact bar is not the original hidden-bar behavior
- [ ] `localPremium`
- [ ] `unlimitedPinnedChats` — needs a real local ordering model, not a raised server limit

### Chat, identity and anti-scam behavior (5)
- [ ] `hideChannelAdsInfo`
- [ ] `chatScrollAnimation` — recovered description requires bubble inertia/depth
- [ ] `scammerProtection` — signed database exists; a verified live UI consumer is missing
- [ ] `deferredMessages`
- [ ] `fakeDeviceName`

### Presence/read history (2)
- [ ] `trackLastOnline`
- [ ] `saveReadDates`

### Profile and media effects (9)
- [ ] `roundProfileButtons`
- [ ] `wgBubbleFisheyeEffect`
- [ ] `profileColorEffect`
- [ ] `avatarBlurEffect`
- [ ] `avatarBlurInProfile`
- [ ] `avatarBlurReduced`
- [ ] `avatarBlurTint`
- [ ] `avatarGlow`
- [ ] `albumArtBlur`

### Other effects and feedback (5)
- [ ] `appBadgeColorIsBlack`
- [ ] `particleEffectPicker`
- [ ] `particleModePicker`
- [ ] `particleSpeedSlider`
- [ ] `particleDensitySlider`

### Remote profile surfaces and remaining text (6)
- [ ] `hideWhitegramUserBadge`
- [ ] `hideWhitegramUserBadgeInfo`
- [ ] `hideOthersCustomMessageStyle`
- [ ] `hideOthersCustomMessageStyleInfo`
- [ ] `iconPackSitePreview`
- [ ] `iconsInfo`

## Gates for marking a feature complete

Build-34646 sources connect `showOriginalTelegramIcons`, `customSettingsIcons`,
`inAppVibration`, `showMutualContactsCard` and `showRegistrationDateCard`.
The 379-test Python suite passes without skips; native build and device checks
are pending. Registration's original persistent caches and known-user prefilter
remain unimplemented. The feedback increment covers the recovered normal-send
hook, not every action mentioned in the original help text. See
[BUILD_34646.md](BUILD_34646.md) for evidence and verification boundaries.

`highlightMentions` and `roundProfileActionButtons` now have runtime consumers
and routes in the build-34643 source increment. Native compilation and clean
simulator launches passed in build 34645; device verification and
exact profile-layout comparison are pending; see
[APPEARANCE_DETAILS_PORT.md](APPEARANCE_DETAILS_PORT.md). These rows are not
counted as unconnected, but are not certified as full parity.

`onlineHistoryEnabled`, `onlineHistoryView` and `onlineHistoryClear` now have
source consumers and UI routes. They are **not marked parity-complete**:
device checks, capture-policy comparison and
original archive migration remain pending. See [ONLINE_HISTORY_PORT.md](ONLINE_HISTORY_PORT.md).
The change is included in [build 34642](BUILD_34642.md), whose native CI suites
and release compilation passed.

For each operational row, establish its recovered behavior and stored types,
connect its control to an installed consumer, verify persistence and refresh,
test repeatable source assembly, compile natively, then exercise the actual
device/network interaction. Do not replace a missing consumer with a writable
preference or mark a whole family complete because its settings screen opens.

The current diagnostic build adds automatic technical crash/hang/service reports
through a private inbox. Receiver delivery has a successful HTTPS-to-GitHub smoke
test. Device capture, symbolication and all existing device checklists remain
separate verification tasks.
