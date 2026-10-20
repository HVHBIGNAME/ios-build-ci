# Login connectivity investigation

The reported failure is before login on an iPhone whose official Telegram works
without VPN or proxy. The exact error text is unavailable. Physical-device
connectivity is not yet confirmed fixed.

## Source findings

- The public fork displayed a proxy recommendation after two seconds, without
  consulting network status. That recommendation is removed from login and the
  main screen. Native connection/authentication errors remain visible.
- Automatic proxy refresh disabled active IP-address proxies and could evict
  manual entries when the feed filled its 40-slot list. Manual entries and the
  active proxy are now retained. Probe updates and rendering the settings list
  no longer switch working connections; automatic selection requires failover.
- Telegram 13's unauthorized account acquired duplicate proxy subscriptions and
  `deinit` blocks when merging the public fork. The resolver keeps the current
  `network.updateProxySettings` observer and disposes the bootstrap once.
- Build 34646 compiled successfully in run 39127878668, but its IPA verifier
  rejected the iPad primary-icon stem `WGPrimary76x76`. Resolution now recognizes
  `@2x~ipad.png` and rejects the wrong device idiom. No simulator check ran there.

## Simulator login check

`simulator_smoke.py --login` first completes the two existing launch checks, then
uses XCUITest on the same owned iPhone simulator. It opens the welcome screen,
enters `+12025550147` (NANPA's reserved fictional range), and presses Continue
and the confirmation button if presented. It does not enter or request a real
user's verification code, retry sends, or create an account.

`WhitegramLoginProbe.swift` is enabled only in simulator builds with a per-run
32-hex token. Through the login account's actual `Network`, it requests
`help.getNearestDc` with a 30-second timeout and records completion of
`auth.sendCode`. It does not change network selection or keep-alive ownership.
The device build returns `EmptyDisposable` and does not run the probe.

The check requires successful UI execution, a matching fresh token, a successful
`help.getNearestDc`, and either a successful `auth.sendCode` or an explicit
`PHONE_NUMBER_INVALID`/`PHONE_NUMBER_BANNED` response for the fictional number.
Timeouts, absent submissions, and API credential errors fail. Server rejection
proves that the request reached Telegram; it does not prove code delivery to a
real account or sideload authentication on an iPhone.

Artifacts include `login-report.json`, `Login.xcresult` (screenshots and
accessibility trees at each step), `xcodebuild.log`, and system logs. The native
record contains only status, numeric RPC codes and bounded symbolic error names.
No phone codes, tokens, request bodies, or account identities are collected.

The workflow's `simulator_only=true` input runs the native/source checks and the
simulator build without first compiling a device IPA. Both build modes use the
same pinned Telegram 13.0 revision and compatibility overlay.

## Current verification

Local source/patch checks and syntax comparison are recorded separately from
the pending native simulator execution. The iOS login result must be taken from
the corresponding Actions run, not inferred from a green source test.

Run 39143097920 passed source validation (399 tests, four original-archive-only
skips), voice/player integration and syntax checks. Two native backend tests
failed on cancellation callback ordering under the new SDK. A diagnostic-only
simulator run continues to collect login evidence after such a failure, then a
final gate restores the failed job result. Full device builds still stop there.

Run 39144601290 passed the native suites on retry. Its first simulator compile
reported moved media eligibility state and changed Speak/ManagedAnimationNode
signatures. The follow-up retains unsupported-media guards, makes the history
render buffer mutable, updates speech calls, and supplies an explicit renderer
for the restored context-free playback icon. Login has not yet executed.

Run 39355192106 compiled the app and passed both 30-second launch checks on
iOS 26.5. XCUITest stopped before execution because the runner lowercased the
simulator UUID; Xcode listed the same device under its uppercase identifier.
The runners now normalize UUIDs to uppercase and preserve the Xcode failure
when native evidence is absent. A new run must still confirm the login RPCs.

The ARM simulator's upstream intro disables OpenGL entirely. That path now
displays the original logo using a tinted, aspect-fit UIKit image, with the
same layout and entrance/snapshot lifecycle. Simulator screenshots check this
static rendering; the device's OpenGL intro still requires device verification.

Run 39422633825 passed source/native checks and compilation, but the first
`simctl launch` timed out before returning a PID. Its pre-install screenshot
still showed the Apple boot screen. The runner now confirms that SpringBoard
can launch and terminate Settings before installing Whitegram, with a bounded
180-second startup timeout. Early failures also retain a screenshot and
SpringBoard/runningboardd/Telegram logs before the owned simulator is deleted.
