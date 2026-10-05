# Whitegram AI and VirusTotal services

The recovered service implementation includes an account-bound adapter to the signed Whitegram provider proxy. Native compilation, XCTest and authenticated device verification of this integration remain pending. The current file maps, defaults, evidence and check results are in [parity/services.json](parity/services.json).

This port provides request/response implementations and interactive SettingsUI screens. The read-only API baseline is `C:/coding/telegram/whitegram/source-12.9.2`, qualified by `C:/coding/telegram/whitegram/recovery_20261002/campaign/reference-ready.json`. All service files below belong in **SettingsUI**, including the Foundation-only files. `WhitegramPreferences` and recovered `WhitegramLocalization` are imported from **TelegramCore**. Text/speech translation has its own module map in [TRANSLATION_PORT.md](TRANSLATION_PORT.md).

## Files

All paths in this table are relative to `whitegram/cleanroom/`.

| File | Responsibility |
| --- | --- |
| `WhitegramAIService.swift` | Gemini/Groq request builders, response decoders, public AI client |
| `WhitegramAIStreaming.swift` | Incremental Groq SSE framing, partial text and terminal-result validation |
| `WhitegramAIModels.swift` | Gemini model pagination and Groq model discovery |
| `WhitegramAISettingsController.swift` | Provider/model/key configuration, transcript, send/cancel/retry/clear, response viewer/copy |
| `WhitegramAIConversation.swift` | Account/provider-scoped persistence, revision arbitration, multi-turn lifecycle |
| `WhitegramAILegacyHistory.swift` | Original v5 role/text JSON import without invented metadata |
| `WhitegramVirusTotalService.swift` | Hash/URL/IP report requests, typed statistics/engine results, unknown-report handling |
| `WhitegramVirusTotalTargets.swift` | Target normalization, validation and message-text/link extraction |
| `WhitegramVirusTotalMessageContext.swift` | Native entity adapter and preference-aware target submission |
| `WhitegramVirusTotalFileHasher.swift` | Security-scoped, coordinated, incremental SHA-256 file hashing |
| `WhitegramVirusTotalUpload.swift` | Private disk-backed multipart snapshot of the exact hashed bytes |
| `WhitegramVirusTotalScan.swift` | Fixed connection probe, URL submission, file reanalysis/upload, bounded status polling |
| `WhitegramVirusTotalController.swift` | File/indicator review, hash/lookup/upload/resume, statistics, engine results, report link |
| `WhitegramServiceCore.swift` | Errors, limits, cancellation/completion arbitration, request gate/backoff |
| `WhitegramServiceHTTP.swift` | Bounded ephemeral URLSession transport, redirect refusal, request construction |
| `WhitegramServiceProxy.swift` | Account-bound clients, signed backend routing, provider-key forwarding, SSE/upload adaptation |
| `WhitegramServiceCredentials.swift` | Keychain adapter, testable migration policy, preference-aware public callbacks |
| `WhitegramServiceUI.swift` | Target ItemListController adapter, account connection/access status, retained native presenters, text editor/viewer, clipboard |

## Parent integration

The assembler must import **all eighteen entries** from `service_patches.SERVICES_RUNTIME_FILES` into SettingsUI, together with the backend runtime described in [BACKEND_PORT.md](BACKEND_PORT.md), and route the appropriate menu/settings actions to:

```swift
public func whitegramAISettingsController(context: AccountContext) -> ViewController
public func whitegramVirusTotalController(context: AccountContext) -> ViewController
```

For a selected message or an already-known file hash:

```swift
public func whitegramAISettingsController(context: AccountContext, text: String?) -> ViewController
public func whitegramVirusTotalController(context: AccountContext, sha256: String?) -> ViewController
public func whitegramVirusTotalController(context: AccountContext, targets: [WhitegramVirusTotalTarget]) -> ViewController
public func whitegramVirusTotalController(context: AccountContext, message: EngineMessage) -> ViewController
public func whitegramVirusTotalController(context: AccountContext, fileURL: URL, fileName: String) -> ViewController
```

The AI overload opens a prefilled composer. “Use Text” returns to the settings screen; **Send Prompt** is the submission action. VirusTotal overloads open review screens. Indicator lookup, Telegram attachment download, and upload are distinct explicit actions. Opening a screen makes no request. The message-menu action is gated by `virusTotalEnabled` and excludes secret chats.

`service_patches(patches: SourcePatches)` composes in memory; `apply_service_patches(root)` writes only after every anchor is validated. It transforms `submodules/TelegramUI/Sources/ChatInterfaceStateContextMenus.swift`. Apply to the assembled baseline after the public/compatibility overlay. Replay and history-menu composition are checked against the ready reference.

The controllers use the target's `ItemListNodeEntry.item(presentationData:arguments:)` and `ItemListController(context:state:)` APIs. The latter convenience initializer is defined in **PresentationDataUtils**, which is explicitly imported. Coordinators are retained by the controller's state signal/lifecycle closures; controller back-references are weak. Native document-picker and presentation delegates remain retained for their presentation lifetime.

The parent still owns source installation/discovery, menu/catalog routing, chat-selection actions, plugin bindings, exports and the app build. Route credential editing to these masked Keychain editors rather than a generic plaintext preference editor.

### Modules and frameworks

- Telegram modules: **AccountContext, Display, ItemListUI, PresentationDataUtils, SwiftSignalKit, TelegramCore, TelegramPresentationData**. These are already dependencies in the inspected SettingsUI `BUILD`.
- Apple SDK: **Foundation, CoreFoundation, UIKit, Security, UniformTypeIdentifiers, CryptoKit, Darwin**.
- File hashing requires **iOS 13.4+ / macOS 10.15.4+**, including the throwing `FileHandle.read(upToCount:)` API. Earlier systems receive a hashing-unavailable error and can enter a hash manually. The iOS 14 document-picker initializer has an older-API fallback.
- `FoundationNetworking` is conditionally imported only where the host Swift toolchain needs it.
- No provider SDK, downloaded model package or third-party networking/crypto dependency is required.

## Public callback APIs

These preference-aware functions require the corresponding enabled flag and load the credential from Keychain. They can be called from a chat/plugin integration after explicit user submission:

```swift
@discardableResult
public func whitegramGenerateAIText(
    _ text: String,
    account: WhitegramAccountServices? = nil,
    completion: @escaping (Result<WhitegramAIResponse, WhitegramServiceError>) -> Void
) -> WhitegramServiceTask

@discardableResult
public func whitegramLookupVirusTotalHash(
    _ sha256: String,
    account: WhitegramAccountServices? = nil,
    completion: @escaping (Result<WhitegramVirusTotalLookupResult, WhitegramServiceError>) -> Void
) -> WhitegramServiceTask

// Static method on WhitegramVirusTotalFileHasher:
@discardableResult
public static func hash(
    url: URL,
    progress: ((Int64, Int64) -> Void)? = nil,
    completion: @escaping (Result<WhitegramVirusTotalFileHash, WhitegramServiceError>) -> Void
) -> WhitegramServiceTask
```

- Completion is **asynchronous, exactly once, on the main queue**, including validation errors and cancellation. Hash progress also runs on the main queue.
- Keep the returned task and call `cancel()` when the caller ends. Discarding the task does not cancel it. Cancellation wins over a success queued but not yet delivered to the main queue.
- The settings screens cancel active work when leaving the screen or entering the background, and use operation IDs to discard stale results. Presenting their own editor/picker does not end the screen's lifetime.
- Public low-level clients are also available: `WhitegramAIService.generate(text:provider:model:apiKey:route:completion:)` and `WhitegramVirusTotalService.lookup(sha256:apiKey:completion:)`. These take explicit credentials and do not consult the enabled preferences. Prefer the wrappers for app integration; `.shared` clients use the direct route.
- Clients accept a `WhitegramServiceTransport` for testing. The default transport uses URLSession. `WhitegramServiceCancellable` supplies `cancel()`.
- `WhitegramServiceStreamingTransport` supplies serial stream callbacks. `WhitegramServiceUploadTransport` must complete only after it has stopped reading the body file, including cancellation. The URLSession implementation retains the completion/snapshot through session invalidation.
- UI connection-status persistence is performed by the controller, not by low-level or preference-aware callback clients.

Additional callbacks are `whitegramLookupVirusTotalTarget`, `whitegramScanVirusTotalTarget` and `whitegramUploadAndScanVirusTotalFile`. They accept the same optional `account` parameter; their full typed signatures are in `WhitegramVirusTotalMessageContext.swift`. Low-level `WhitegramVirusTotalService` also exposes `testConnection`, `scan`, `resumeAnalysis` and `uploadAndScan`. Scan progress distinguishes preparing, the prepared file hash, upload, accepted submission, and pending analysis. A returned analysis is successful only at `status == completed`.

### Account-bound proxy integration

Create and retain `WhitegramAccountServices(userId:)` using the **Telegram CloudUser numeric ID** (`context.account.peerId.id._internalGetInt64Value()`). `AccountRecordId` is used for local conversation storage, not backend authorization. Pass this object to preference-aware callbacks. An omitted account works only when the configured route is explicitly direct; it never selects an arbitrary active Telegram account.

`services.ai(route:)` and `services.virusTotal(route:)` reuse each account's proxy clients and request gates. AI low-level calls must also receive the matching `route:` argument. The native AI and VirusTotal coordinators retain these clients, expose **Connect / Refresh Whitegram Access**, and cancel connection/request work on their existing screen/background lifecycle. Connection uses `WhitegramBackendAuthentication(context:)`; access/session notifications refresh the status only for the matching user.

The adapter routes generation, model discovery, indicator lookups, submissions and polling through `WhitegramBackendAuthorizedTransport`:

| Provider | Signed backend path |
| --- | --- |
| Gemini | `/v1/proxy/gemini/v1beta/models` and `/v1/proxy/gemini/v1beta/models/{model}:generateContent` |
| Groq | `/v1/proxy/groq/openai/v1/models` and `/v1/proxy/groq/openai/v1/chat/completions` |
| VirusTotal | `/v1/proxy/virustotal/v3/...` |

Gemini pagination stays in separately encoded query items. Provider credentials become `X-Provider-Key`; the backend retains its own Whitegram `Authorization`, application/device/session signatures, verified access and pinned TLS. Provider status, error body and Retry-After are preserved, including JSON VirusTotal 404s. Groq consumer errors remain typed across the backend boundary. Session replacement/revocation stops active work; there is no retry against a direct provider.

Proxy upload destinations must be in the official `/api/v3/` namespace or the backend's `/v1/proxy/virustotal/v3/` namespace and are normalized to the backend origin. Direct-only `/_ah/upload/` URLs are rejected in proxy mode. The historical server's large-file upload response needs device verification; this adapter does not invent another signed upload endpoint. Upload completion waits for the backend to stop reading the caller-owned body file, including after cancellation.

## Implemented behavior

### Gemini and Groq

| Provider | Request | Authentication |
| --- | --- | --- |
| Gemini | `POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent` | `x-goog-api-key` header |
| Groq | `POST https://api.groq.com/openai/v1/chat/completions` | `Authorization: Bearer …` header |

The low-level single-text API sends one user message. The conversation screen sends the **exact submitted text plus completed turns from that account/provider's local AI conversation**. It does not collect Telegram chats, account identifiers, attachments or clipboard contents. Gemini uses `user`/`model` roles in `contents`; Groq uses `user`/`assistant` roles in `messages`. Invalid role sequences and oversized encoded conversations are rejected before a request starts.

Model IDs are editable strings. Absent preferences use the recovered getters' defaults: **`gemini-3-flash-preview`** and **`llama-3.3-70b-versatile`**. This does not assert current model availability. Explicit model preferences are retained and errors never switch models. Gemini accepts a bare ID or `models/` prefix; Groq accepts namespaced IDs. The provider defaults to Gemini only when absent; an unrecognized/empty saved value requires explicit selection. Gemini's original model allow-list filter is not used to overwrite custom model selections.

Model discovery calls `GET /v1beta/models?pageSize=20[&pageToken=…]` for Gemini and `GET /openai/v1/models` for Groq. Only Gemini models advertising `generateContent` and Groq models not explicitly inactive are shown. Groq's list may include non-text models. Listing access is not represented as generation access.

Gemini decoding selects candidate index 0 (or the first candidate if indices are absent), concatenates its text parts, excludes `thought` parts, and handles prompt/candidate blocking. Its recovered `generateContent` flow supplies a completed text callback. Groq's conversation flow consumes SSE incrementally across arbitrary UTF-8/CR/LF boundaries. It requires a terminal finish reason and `[DONE]`; premature EOF is not success. Output-limit replies are marked partial. Tool requests, including mixed text/tool output, fail explicitly because Telegram tool execution is not connected. Token counts are displayed only when supplied.

Conversation turns persist beneath `<account.basePath>/whitegram-ai-v1/<accountId>/{gemini,groq}.json`, bounded to 100 current turns and 8 MiB. Failed/cancelled prompts and partial text stay visible but are excluded from subsequent context. Retry replaces the last unfinished turn. An explicit new prompt after a restart can supersede an interrupted pending turn. Clearing writes an empty revision, preventing stale replies from restoring cleared history. Copy is explicit, device-local and expires after one hour.

Original `wg_geminiChatHistory_v5`/`wg_groqChatHistory_v5` values are JSONEncoder **Data** containing up to 200 `{role,text}` entries; **both** providers stored `user`/`model` roles. Import is explicit because the source is app-wide and records no account. It copies exact entries to an empty account/provider store, retains the original Data, and invents no dates/models. Orphan assistant and unanswered user entries remain visible; only complete adjacent pairs enter new context. Malformed/oversized histories are preserved and rejected. The current version-1 record gained optional `legacyHistory` and `partialText` fields; old records remain decodable.

### VirusTotal

Direct requests use `GET /api/v3/files/{sha256}`, `/urls/{base64url-id}` or `/ip_addresses/{address}` at `https://www.virustotal.com`, authenticated by `x-apikey`. They share one gate/backoff with submissions. Direct API requires explicit selection in the native settings screen; absent route state preserves the original proxy requirement.

- URL scan: form-encoded `POST /api/v3/urls` preserving the reviewed query parameters.
- Existing file reanalysis: `POST /api/v3/files/{sha256}/analyse`.
- Upload: multipart `POST /api/v3/files` through **32 MiB inclusive**; larger files first obtain `GET /api/v3/files/upload_url`. In direct mode, returned upload URLs must remain on `https://www.virustotal.com` at an allowed upload path. Proxy mode uses the namespace restrictions above. No redirect forwarding is allowed.
- Status: `GET /api/v3/analyses/{id}`, at most **20 checks**, normally 15 seconds apart. Queued/in-progress/empty statistics never become a clean verdict. Bounded GET rate-limit delays are supported; POST is never retried automatically.
- Connection test: lookup the original fixed **`https://vk.com`** probe. It does not submit that URL for scanning.

`service_patches.py` adds a message-context action for extracted HTTP(S) links, IPv4/IPv6 addresses and SHA-256 indicators. Telegram link entities take precedence over plain-text detection; indicators are deduplicated and bounded. The action opens a review/selection screen. Only an explicit Look Up sends the chosen indicator, including URL query parameters, to VirusTotal. Other message text is not sent. Secret-chat context actions are excluded.

The native document picker opens one file without copying it into app storage. Hashing uses a background queue, a security-scoped URL, `NSFileCoordinator`, `FileHandle` reads and incremental `CryptoKit.SHA256`. It checks the size before/while reading, rejects directories/packages/symlinks, and checks descriptor/path identity, size and modification metadata after reading. File-provider materialization may occur through the system file provider; no file contents are sent to VirusTotal. Cancelling interrupts coordination and stops reading at a chunk boundary; completion can be delivered while system file-provider cancellation finishes.

After hashing, the user explicitly taps **Look Up SHA-256** or confirms **Upload File & Scan**. Upload builds a private multipart file while hashing its exact bytes again, checks any previously reviewed hash, and retains that snapshot until URLSession has stopped reading it. The prepared hash becomes the report target even for a file opened without a prior hash. Temporary snapshots are removed after use. Manual hash entry requires exactly 64 hexadecimal characters.

Reports expose:

- The verified SHA-256 resource identity; a mismatched report is rejected.
- Actual `last_analysis_stats`, preserving absent statistics as absent.
- Actual engine names, categories, detection names, versions and update dates.
- `last_analysis_date` when supplied.
- A canonical `https://www.virustotal.com/gui/file/{sha256}/detection` URL. Response-supplied links are not used for navigation.

VirusTotal's JSON `404 / NotFoundError` maps to `.notFound(sha256:)` and is displayed as **unknown**, never clean. An unrecognized/HTML 404 remains a failed lookup rather than a fabricated report. Missing/empty/inconclusive statistics remain unknown. Zero detections are described only as “no detections in the returned statistics”; engine findings can override a zero-statistics summary. Report age is displayed.

### Request limits and failure handling

- Prompt: **32 KiB UTF-8**. Encoded request: **256 KiB**.
- Generation budget: **4,096 output tokens**. This may include a model's reasoning budget; a model that returns no visible text gets a no-text error.
- Response: **2 MiB AI**, **4 MiB VirusTotal**, enforced against declared length and accumulated chunks.
- File: **512 MiB**, read in **1 MiB** chunks; empty files are supported.
- Direct idle/request timeout: **45 s**; resource timeout: **90 s**. The backend uses **30 s / 60 s**. Both upload resource timeouts are **600 s**. Native attachment download is bounded to **300 s**.
- One HTTP request at a time per client. Shared direct and retained account-bound AI clients: at least **1 s** between starts. VirusTotal clients: at least **15 s**. Cancellation does not refund this spacing.
- `429` and `503` with `Retry-After` extend backoff. Seconds and HTTP dates are supported; malformed/missing 429 values use 60 s, extreme values are capped at seven days. Only analysis-status GETs retry bounded rate limits (at most 300 seconds per delay and within the 20-check budget). Generation, report lookup, model discovery and POST submission are not automatically retried.
- HTTP authentication/permission/model errors, offline/timeout failures, oversized responses, bad JSON and cancellation are surfaced as fixed errors. Raw provider error bodies and URLSession descriptions are not displayed or logged.
- Sessions are ephemeral with cache, cookies and shared URL credential storage disabled. All redirects are refused, including same-host redirects, so API-key headers are never forwarded by redirection. Normal system TLS validation is retained.
- Cancelling ends the local operation; it cannot retract text a provider already received.

## Preferences and credential migration

| Recovered key | Use |
| --- | --- |
| `geminiEnabled` | Master enable for the selected AI provider (the recovered metadata has one AI enable key) |
| `aiProvider` | `gemini` or `groq`; existing case variants are read case-insensitively |
| `geminiModelId`, `groqModelId` | Separate editable model strings |
| `geminiApiKey`, `groqApiKey` | Legacy credential lookup keys and Keychain account names; new tokens are not saved in preferences |
| `geminiUseProxy`, `groqUseProxy` | Original default **true**. Uses the account-bound signed proxy; only explicit false selects Direct API |
| `virusTotalEnabled` | Enables hash/URL/IP HTTP lookups; local hashing can be used independently |
| `virusTotalUseProxy` | **New Bool, default true**, mirrors `wg_virusTotalUseProxy`. Explicit false enables Direct API; original VirusTotal had a mandatory proxy |
| `virusTotalApiKey` | Legacy lookup key and Keychain account name |
| `virusTotalConnectionStatus` | Timestamped string from the current controller's real request outcome; cleared when its key changes |

Direct networking uses the system's URLSession configuration. The recovered proxy path requires an account-bound signed Whitegram session, beta permission, pinned TLS and **`X-Provider-Key`**, retaining Whitegram's `Authorization` header. The adapter now consumes the backend's status-preserving, SSE and body-file transport contract. Original addresses and integration details are recorded in the services handoff. Missing sessions/signing configuration, denied/unverified access and changed sessions have distinct fixed errors. No original-proxy flag silently selects Direct API. Historical saved connection strings are not treated as a fresh check.

Keys use generic-password Keychain items with:

- Service: `<Bundle.main.bundleIdentifier>.Whitegram.Services.v1` (fallback bundle name `Whitegram`).
- Account: the corresponding recovered API-key preference name.
- Accessibility: `kSecAttrAccessibleWhenUnlockedThisDeviceOnly`.
- Synchronization: disabled. Default app Keychain access group; no new shared-group entitlement.

The credential policy prefers an existing Keychain value, otherwise migrates from shared preferences, `wg_<key>` mirrors, direct legacy defaults, and the known `WhitegramPrivacySettings.v1` JSON. A successful secure write precedes removal/blanking of legacy values. Failed writes preserve the legacy value for retry. Failed cleanup or Keychain access blocks credential use; it never triggers a plaintext networking fallback. Credential-change notifications carry only the credential enum, and are posted outside the vault lock. Service UI observers do not block background migrations waiting for a main-queue vault read.

The parent should call this on startup and before export:

```swift
public func whitegramMigrateServiceCredentials()
    -> [WhitegramServiceCredential: WhitegramServiceError]
```

This helper performs no network operation and returns only fixed errors. **The parent export path must exclude `geminiApiKey`, `groqApiKey`, `virusTotalApiKey` and their `wg_` mirrors regardless of migration success.** These screens have no token export, but they cannot change a separately-owned generic exporter or stale generic settings snapshot. Keep credential editing out of generic plaintext rows; replacing a legacy preference does not override an already-secure Keychain token.

Service preferences/keys follow the existing app-wide Whitegram preferences scope, not Telegram login/account Keychain storage.

## Tests and verification

`whitegram/tests/services/` contains **83 XCTest methods** against production builders, decoders, SSE framing, quota gates, conversation persistence, v5 import and credential policy, plus URLSession through an intercepting URLProtocol. Apple-only cases exercise file hashing, multipart snapshots, the 32 MiB threshold, delayed upload cancellation and redirects. These methods were **not executed on this Windows host**.

Run on a Swift-capable host:

```text
python3 -B whitegram/tests/services/run_swift_tests.py
```

The runner copies the thirteen non-UI production files into an isolated, dependency-free SwiftPM host beneath `tests/services/.host-package`, records SHA-256 digests, and keeps build/cache/temp artifacts beneath `tests/services/.host-artifacts`. It does not compile a substitute service implementation. It accepts `--swift <executable>` and `--filter <XCTest filter>`.

The account-bound adapter has **13 additional XCTest methods** in `tests/backend/WhitegramServiceProxyTests.swift`. Run `python3 -B whitegram/tests/backend/run_native.py` on macOS. This runner copies 32 production files, including the actual service/proxy/backend implementations, and is already called by the native CI stage. Cases cover signed provider routing, model queries, missing/expired/mismatched sessions, access/signing failures, route/account requirements, status bodies, rate limits, session replacement, Groq SSE/errors, VirusTotal polling/upload URLs and cancellation after the file reader stops. These methods have only been syntax-checked here; the runner reports macOS is required on this Windows host.

- macOS: all 83 methods are supplied. The SwiftPM package targets macOS 10.15.4+.
- Linux: Foundation tests are available; CryptoKit/Darwin hashing and upload-file cases are excluded. The redirect test skips FoundationNetworking's unimplemented URLProtocol redirect callback.
- No tests require real credentials or permit a request to reach a provider. URLSession tests install a URLProtocol that intercepts every URL; the other client tests inject a manual transport.
- The native Security/TelegramCore adapter, settings UI, signing, native picker presentation and actual API access still need the app's Apple build/device verification.

Offline syntax/source-contract check used in this Windows workspace:

```text
C:\coding\telegram\whitegram\whitegram-check-env\Scripts\python.exe -B whitegram/tests/services/check_sources.py --target C:\coding\telegram\whitegram\source-12.9.2
```

This checks Swift syntax, target controller signatures/imports, endpoint/auth-storage invariants, masked editors and bounded reads. It is **syntax/static validation, not Swift compilation or runtime verification**. The current check covers eighteen production and eight direct-service test Swift files; `test_backend_patches.py` parses the backend and proxy XCTest sources. `test_service_patches.py` supplies three source tests, including runtime/handoff map equality, fail-before-write and history composition; set `WHITEGRAM_ASSEMBLED_SOURCE` to the read-only ready reference. No provider request or device execution is claimed.

The **2026-10-05** proxy increment passed 43 Python checks: three service source/manifest tests, seven backend source/composition tests, seven protocol-evidence tests and 26 full-composition/runtime/build-dependency tests. The service parser/contracts and tracked whitespace check also passed. Exact commands and reference/candidate paths are in `proxy_integration_checks` in the parity manifest. Native runners reported unavailable macOS/Swift rather than a test pass.

## Remaining integration/unsupported features

- Apple-host and authenticated server validation of the signed proxy adapter, including original model paths, session/access changes, SSE and the large-file upload response namespace.
- Original AI Telegram tool execution, audio/image/file inputs, dynamic/tuned model endpoints and any additional plugin bindings. Text-only replies never claim that an unconnected tool executed.
- Exact retired-AI menu eligibility is parent-owned; original 3.1.1 has no active AI main section. Existing history and credentials are preserved.
- Native Swift/UIKit/Security build and provider/device validation. No live credentials, API requests or scans were used in development.
- Original setting titles use verified ru/uk/en localization keys. Additional workflow/error explanations remain English; no new translations were presented as recovered originals.

### Official protocol references

- Gemini: <https://ai.google.dev/api/generate-content>; its official REST binding is also in <https://github.com/googleapis/googleapis/blob/master/google/ai/generativelanguage/v1beta/generative_service.proto>.
- Groq: <https://console.groq.com/docs/api-reference#chat-create>.
- VirusTotal: <https://docs.virustotal.com/reference/file-info> and <https://docs.virustotal.com/reference/files>.
