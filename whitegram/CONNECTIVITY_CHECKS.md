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

Run 39426484990 stopped even earlier: the fresh iOS runtime had not completed
data migration within the 240-second boot limit. Logs show SpringBoard waiting
for migration and the screenshot retains Apple's progress bar; Whitegram was
not installed. Boot now opens the Simulator display first and allows up to
600 seconds for initial migration, retaining `bootstatus.log` on timeout too.

Run 39431117074 passed both launches and XCUITest; the original logo is fully
visible in both welcome screenshots. `help.getNearestDc` succeeded and
`auth.sendCode` received `PHONE_MIGRATE_1`. The migrated request then hit the
login flow's timeout, displaying the native connection error. This proves
initial connectivity, not completed login. Diagnostics now observe the actual
auth request's data center, connection and keep-alive demand, preserve bounded
RPC response history, and record the outer authorization timeout without
changing its existing 20-second deadline or retry behavior.

Run 39501174838 confirmed DC2-to-DC1 migration, active keep-alive and an online
DC1 connection, but the migrated request still timed out. System logs show the
reCAPTCHA SDK starting verification during this flow. Follow-up diagnostics
record challenge/client/execution stages and numeric SDK error codes, plus
relative event timing. They retain neither verification secrets nor SDK error
messages and leave both verification providers and authorization timing intact.

Run 39513169757 compiled the verification diagnostics, but stopped before app
installation when the auxiliary Settings termination timed out. The readiness
check now requires a live Settings PID and leaves Settings running; launching
Whitegram brings the tested app to the foreground normally. This run also
exposed a native backend cancellation-order test failure, retained by the
workflow's final gate. Neither failure supplies new login evidence.

## Confirmed package-verification blocker

Run [39521822835](https://github.com/HVHBIGNAME/ios-build-ci/actions/runs/39521822835)
passed compilation, both launches and XCUITest. DC1 became online roughly
0.2 seconds after the redirected request started. The reCAPTCHA client loaded,
then execution failed with SDK code **4**, which the shipped SDK declares as
`errorInvalidPackageName`. The remaining login flow expired at its 20-second
deadline. This is a package-verification rejection, not evidence of an offline
Telegram connection. The report now names that confirmed cause explicitly.

The affected run inherited upstream `api_id=8`, while its installed bundle was
`whitegram.telegra.Telegraph`. At that point the repository had no project-owned
Telegram API credentials configured. `configure.py` now accepts the pair
`WHITEGRAM_TELEGRAM_API_ID` / `WHITEGRAM_TELEGRAM_API_HASH` from environment
variables, validates both before writing, and the workflow reads these from
GitHub Secrets in its configuration step. With no pair supplied, the existing
upstream configuration is retained; this does not resolve the observed blocker.

Obtain the project's pair through [Telegram API development tools](https://my.telegram.org/apps),
then add both as repository Actions secrets and rerun `simulator_only=true`.
Telegram's [API setup documentation](https://core.telegram.org/api/obtaining_api_id)
requires a third-party application to obtain its own API ID. Whether the new
credentials resolve this package rejection must be verified by a fresh run.
The observed server-provided reCAPTCHA key cannot be registered or changed by
this build. Real-account code delivery and physical-device login remain unverified.

## Project-owned API verification — 2026-10-21

Both Telegram API secrets were added on 2026-10-21. Run
[39529151012, attempt 2](https://github.com/HVHBIGNAME/ios-build-ci/actions/runs/39529151012/attempts/2)
used the new configuration and passed source checks, native suites,
compilation, both 30-second launches and XCUITest. Attempt 1 had stopped before
Whitegram installation on a simulator Settings startup timeout.

With the project credentials, `help.getNearestDc` succeeded and the redirected
DC1 request returned **`420 FLOOD_WAIT_33385`** instead of hanging: Telegram
requires **9 hours 16 minutes 25 seconds** from that response before another
attempt. The UI displayed the native "Too many attempts" alert. No reCAPTCHA
challenge was observed in this run, but a rate limit can precede verification;
this does **not** establish that package verification has been resolved.
The login gate stays failed, and no further auth request is being made during
the cooldown. The runner now reports this server cooldown explicitly.

The MTProto server addresses on the developer portal already match the client
seeds (`149.154.167.50:443` production, `149.154.167.40:443` test). No manual
address or RSA public-key installation is needed. The check uses production;
test accounts and keys belong to a separate environment. FCM credentials are
for Firebase messaging, WNS package SID for Windows notifications; neither
is required for this iOS simulator login check or fixes the package rejection.
Physical-device notifications require separate APNs/signing verification.

## Device IPA and launch-only verification — 2026-10-21

Run [39539144691](https://github.com/HVHBIGNAME/ios-build-ci/actions/runs/39539144691)
passed source validation, native suites, device compilation and IPA verification
on revision `81ff17b5340dd7c656b930a94d990fc775728fb9`. The published
[WhiteGram-13.0-34648-unsigned artifact](https://github.com/HVHBIGNAME/ios-build-ci/actions/runs/39539144691/artifacts/12321669148)
contains `WhiteGram-13.0-34648.ipa` and `WhiteGram-verification.json`.
The downloaded IPA's size (82,386,629 bytes) and SHA-256
`b071dccaf15e343a44dd7d24e1d087552c056dc353803eac0b433b1fc60c156d`
match the report. The app is arm64, version 13.0, build 34648, with bundle ID
`whitegram.telegra.Telegraph`. Installation requires signing. The subsequent
physical-device result is recorded below.

Although Actions marked that run successful, its simulator launch invocation
stopped on macOS Bash's `login_args[@]: unbound variable` with `login_check=false`.
There is no launch report or screenshot for that run. Revision
`44ba0ecadbdd6a20b3050fa4c7d933eac580a87d` replaces the optional empty array
with positional arguments, checked locally with login enabled and disabled.
The workflow's `login_check` input defaults to true; disabling it omits the
phone-entry/authentication check while retaining both launch observations.

Run [39602054471](https://github.com/HVHBIGNAME/ios-build-ci/actions/runs/39602054471)
passed source/native checks, compilation and both 30-second launches on `44ba0ec`
with `login_check=false`. The retained report identifies iPhone Air / iOS 26.5,
both processes survived the observation and screenshot windows, and cleanup
completed without errors. The UIKit welcome logo is visible in the screenshots.

## Physical-device return to login — build 34648

The user installed the IPA through ESign/Feather and reported that confirming
login immediately returned to the welcome screen without terminating the app.
Telegram sent a new-device login notification at 2026-10-21 12:54:42 UTC, and
the WhiteGram session remained listed in the official client's Devices screen.
This establishes a server-created session from the user's observation; the
client's local account transition is still failing. No device journal for that
attempt is available, so the precise cause is not yet confirmed.

The build-34649 candidate protects `TelegramEngineUnauthorized.Auth.setState`
against overwriting an `AuthorizedAccountState` with a late login-screen write.
It also retains a bounded, local technical journal of sign-in response codes,
account-state loading, account publication, network logout and UI readiness.
Hold the welcome screen for two seconds to export that journal if login returns
there again. The export contains no phone numbers, codes, account IDs or keys,
and is not automatically uploaded. It follows the existing diagnostics opt-out.
This defensive guard is not yet evidence that the user's failure is fixed.

The device screenshot also showed OpenGL layers underneath the logo. The
candidate renders the first welcome page with the original template UIImage,
the same 148/200 inset and theme tint as the simulator. OpenGL remains visible
for the later intro pages. Device appearance still needs a fresh screenshot.
Local validation passed 430 Python tests (45 environment/original-archive skips),
including full installer composition and repeat application. Native execution
of the new candidate is pending.

Run [39622301956](https://github.com/HVHBIGNAME/ios-build-ci/actions/runs/39622301956)
passed source validation, native suites (including the persisted/bounded session
journal test), device compilation and IPA verification on
`620bed1d2dff271f740753fad454cec0a667120a`. The
[build-34649 IPA](https://github.com/HVHBIGNAME/ios-build-ci/actions/runs/39622301956/artifacts/12357878728)
is 82,394,257 bytes; the downloaded SHA-256 matches the report:
`d7ac7f2ca0caaa4104959a2145d26efc925b4da7266e5189071991e46f44b16c`.
The overall run failed later because the simulator compiler rejected the
device-only UIKit setup as unreachable after the ARM simulator's early return.
That setup is now conditionally compiled only on its device/Intel path.
No simulator launches ran in this build, and its physical-device login result
still awaits the user's test/journal.
