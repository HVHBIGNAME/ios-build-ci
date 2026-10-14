# Temporary automatic error reporting

Reports go from the app's HTTPS uploader to a loopback-only Python receiver,
then to **HVHBIGNAME/whitegram-diagnostics (private)** using the receiver's existing
`gh` authentication. The app has a report-only intake key, never a GitHub token.
Build metadata comes from `WHITEGRAM_DIAGNOSTICS_URL`,
`WHITEGRAM_DIAGNOSTICS_UPLOAD_KEY` and `GITHUB_SHA` during IPA postprocessing.

## Captured information

- iOS 14+ MetricKit crash and hang diagnostics: binary names, UUIDs, relative
  instruction offsets, thread/depth and the crash signal/exception type.
- Direct-service and signed-backend HTTP status errors and URLSession numeric
  transport errors. Cancellations are omitted.
- Selected service failures: invalid responses (1001), oversized responses (1002),
  oversized requests (1003), refused redirects (1004), conversation storage (1005),
  preferences (1006), unreadable files (1007), signing configuration (1008), and
  native Keychain status codes.
- App version/build, source revision, OS version and report reception time.

MetricKit delivers reports asynchronously, commonly after a later launch; it is
not an immediate crash callback and does not guarantee a report for every process
termination. A diagnostic from an older app build uses its original build number
and `unknown` revision rather than attributing it to the current binary. Match
binary UUIDs against the archived symbols. New builds must increment the build
number (this increment uses **34640**).

No raw Telegram logs, request URLs/headers/bodies, error descriptions, exception
reasons, message content, phone numbers, account IDs, credentials or device names
are sent. The receiver rejects fields outside the technical schema.

## Delivery and controls

**Diagnostics → Automatically send errors** controls collection and delivery.
It defaults on in this explicitly requested diagnostic build; an unconfigured
build cannot upload. Turning it off cancels delivery/retries and clears pending
reports. **Send test report** checks the pipeline without intentionally crashing.
The screen shows queue/delivery status.

The app keeps at most 32 pending reports, suppresses repeated fingerprints for
five minutes, expires reports after seven days, and retries with bounded backoff.
An acknowledgment must include the matching report UUID before an entry is removed.
Uploads use system TLS, refuse redirects, and accept at most 4 KiB of response data.

The receiver acknowledges only after SQLite commits, caps incoming bodies at
64 KiB and the backlog at 1024, and limits accepted new reports to 120/hour.
Retries of the same UUID are idempotent. Distinct occurrences share an issue by
source revision, category, code and top stack frames. Repeated occurrence counts
remain in SQLite; the issue contains the first diagnostic. Delivered records are
retained locally for 30 days. GitHub issues are retained until explicitly removed.

## Temporary operation

`diagnostics/start_receiver.py --state-root <existing-directory> --repository
HVHBIGNAME/whitegram-diagnostics --build-repository HVHBIGNAME/ios-build-ci`
starts the loopback receiver and a Cloudflare quick tunnel. `--provider tailscale`
uses Tailscale Funnel on HTTPS port 8443 after the account owner enables Funnel.
The launcher verifies public health before setting the two GitHub build secrets.
It refuses to replace an existing Tailscale serve configuration.

Runtime files are outside the repository. `config.json` contains the upload key:
do not commit or paste it. `runtime.json` contains the public endpoint and process
IDs. Keep the computer and receiver running while testing on the phone. A
Cloudflare restart changes its URL and requires new build configuration; the
Tailscale hostname is stable.

Use `diagnostics/smoke_test.py --state-directory <runtime-directory>` to send a
synthetic report twice and verify that exactly one private issue is created.
The public receiver requires its upload key; `/health` returns only service/instance
identity. Disable the Tailscale endpoint with `tailscale funnel --https=8443 off`.
Stopping the receiver or removing the GitHub build secrets does not change an
already installed IPA; disable reporting in the app or revoke its intake key.

## Verification and remaining checks

Local Python tests exercise schema rejection, authenticated HTTP acceptance,
durability across GitHub outages, idempotent retries, grouping, source installation
and Swift parsing. Native XCTest covers metadata redaction, bounded stack extraction,
delayed-build attribution and matching/oversized/error upload acknowledgments.
The native suite and full app build run in CI. Matching `Telegram.DSYMs.zip`
artifacts are archived with the exact source revision.

Device validation still needs a signed diagnostic IPA: send a test report, verify
normal service errors, disable/re-enable delivery, test an offline retry and check
MetricKit delivery after a real crash/hang. Successful receiver smoke testing alone
does not verify iPhone crash capture.
