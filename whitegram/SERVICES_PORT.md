# Whitegram AI and VirusTotal services

Source installation, main-menu routing and startup credential migration are connected by the parent integration; see [PORT_STATUS.md](PORT_STATUS.md) for the current checks and Apple build checkpoint.

This port provides real request/response implementations and interactive SettingsUI screens. The source API baseline is the assembled `whitegram-port-12.9.2` tree. All implementation files below belong in **SettingsUI**, including the Foundation-only service files. `WhitegramPreferences` is imported from **TelegramCore**.

## Files

All paths in this table are relative to `whitegram/cleanroom/`.

| File | Responsibility |
| --- | --- |
| `WhitegramAIService.swift` | Gemini/Groq request builders, response decoders, public AI client |
| `WhitegramAISettingsController.swift` | Provider/model/key configuration, transcript, send/cancel/retry/clear, response viewer/copy |
| `WhitegramAIConversation.swift` | Account/provider-scoped persistence, revision arbitration, multi-turn lifecycle |
| `WhitegramVirusTotalService.swift` | Hash/URL/IP report requests, typed statistics/engine results, unknown-report handling |
| `WhitegramVirusTotalTargets.swift` | Target normalization, validation and message-text/link extraction |
| `WhitegramVirusTotalMessageContext.swift` | Native entity adapter and preference-aware target submission |
| `WhitegramVirusTotalFileHasher.swift` | Security-scoped, coordinated, incremental SHA-256 file hashing |
| `WhitegramVirusTotalController.swift` | Document picker, manual hash entry, lookup/cancel, statistics, engine results, report link |
| `WhitegramServiceCore.swift` | Errors, limits, cancellation/completion arbitration, request gate/backoff |
| `WhitegramServiceHTTP.swift` | Bounded ephemeral URLSession transport, redirect refusal, request construction |
| `WhitegramServiceCredentials.swift` | Keychain adapter, testable migration policy, preference-aware public callbacks |
| `WhitegramServiceUI.swift` | Target ItemListController adapter, retained native presenters, text editor/viewer, clipboard |

## Parent integration

The assembler installs **all twelve files** into SettingsUI and routes the appropriate menu/settings actions to:

```swift
public func whitegramAISettingsController(context: AccountContext) -> ViewController
public func whitegramVirusTotalController(context: AccountContext) -> ViewController
```

For a selected message or an already-known file hash:

```swift
public func whitegramAISettingsController(context: AccountContext, text: String?) -> ViewController
public func whitegramVirusTotalController(context: AccountContext, sha256: String?) -> ViewController
```

The AI overload opens a prefilled composer. “Use Text” returns to the settings screen; **Send Prompt** is the submission action. The VirusTotal overload prefills a hash for review; **Look Up SHA-256** is still required. Neither entrypoint makes an automatic request.

The controllers use the target's `ItemListNodeEntry.item(presentationData:arguments:)` and `ItemListController(context:state:)` APIs. The latter convenience initializer is defined in **PresentationDataUtils**, which is explicitly imported. Coordinators are retained by the controller's state signal/lifecycle closures; controller back-references are weak. Native document-picker and presentation delegates remain retained for their presentation lifetime.

The parent still owns source installation/discovery, menu/catalog routing, chat-selection actions, plugin bindings, exports and the app build. Route credential editing to these masked Keychain editors rather than a generic plaintext preference editor.

### Modules and frameworks

- Telegram modules: **AccountContext, Display, ItemListUI, PresentationDataUtils, SwiftSignalKit, TelegramCore, TelegramPresentationData**. These are already dependencies in the inspected SettingsUI `BUILD`.
- Apple SDK: **Foundation, UIKit, Security, UniformTypeIdentifiers, CryptoKit, Darwin**.
- File hashing requires **iOS 13.4+ / macOS 10.15.4+**, including the throwing `FileHandle.read(upToCount:)` API. Earlier systems receive a hashing-unavailable error and can enter a hash manually. The iOS 14 document-picker initializer has an older-API fallback.
- `FoundationNetworking` is conditionally imported only where the host Swift toolchain needs it.
- No provider SDK, downloaded model package or third-party networking/crypto dependency is required.

## Public callback APIs

These preference-aware functions require the corresponding enabled flag and load the credential from Keychain. They can be called from a chat/plugin integration after explicit user submission:

```swift
@discardableResult
public func whitegramGenerateAIText(
    _ text: String,
    completion: @escaping (Result<WhitegramAIResponse, WhitegramServiceError>) -> Void
) -> WhitegramServiceTask

@discardableResult
public func whitegramLookupVirusTotalHash(
    _ sha256: String,
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
- Public low-level clients are also available: `WhitegramAIService.generate(text:provider:model:apiKey:completion:)` and `WhitegramVirusTotalService.lookup(sha256:apiKey:completion:)`. These take explicit credentials and do not consult the enabled preferences. Prefer the wrappers and `.shared` clients for app integration.
- Clients accept a `WhitegramServiceTransport` for testing. The default transport uses URLSession. `WhitegramServiceCancellable` supplies `cancel()`.
- UI connection-status persistence is performed by the controller, not by low-level or preference-aware callback clients.

## Implemented behavior

### Gemini and Groq

| Provider | Request | Authentication |
| --- | --- | --- |
| Gemini | `POST https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent` | `x-goog-api-key` header |
| Groq | `POST https://api.groq.com/openai/v1/chat/completions` | `Authorization: Bearer …` header |

The low-level single-text API sends one user message. The conversation screen sends the **exact submitted text plus completed turns from that account/provider's local AI conversation**. It does not collect Telegram chats, account identifiers, attachments or clipboard contents. Gemini uses `user`/`model` roles in `contents`; Groq uses `user`/`assistant` roles in `messages`. Invalid role sequences and oversized encoded conversations are rejected before a request starts.

Model IDs are editable strings. No model availability is fabricated and no fallback model is silently selected. Gemini accepts a bare model ID or the `models/` prefix; Groq accepts namespaced IDs. Unsupported IDs produce the real HTTP error. An unrecognized/empty provider preference requires an explicit provider selection.

Gemini decoding selects candidate index 0 (or the first candidate if indices are absent), concatenates its text parts, excludes `thought` parts, and handles prompt/candidate blocking. Groq decoding selects one choice's `message.content`. Output-limit responses retain their text and are visibly marked partial. Missing text, tool-only output, malformed JSON, unsupported finish states, and invalid metadata produce errors. Token counts are displayed only when the provider supplies them.

Conversation turns persist in account/provider-specific files, bounded to 100 turns and 8 MiB. Failed/cancelled prompts stay visible but are excluded from subsequent conversation context. Retry replaces the last unfinished turn. Clearing writes a new empty revision so another screen's stale response cannot restore cleared history. Full results are selectable plain text. Copy is explicit, device-local and expires after one hour. Original `wg_geminiChatHistory_v5`/`wg_groqChatHistory_v5` keys identify the recovered feature, but their backup format is not claimed compatible with this new store.

### VirusTotal

Read-only requests use `GET /api/v3/files/{sha256}`, `/urls/{base64url-id}` or `/ip_addresses/{address}` at `https://www.virustotal.com`, authenticated by `x-apikey`, with no request body. URL/IP reports share the file lookup's gate/backoff. There is no file-upload or scan-submission implementation.

`service_patches.py` adds a message-context action for extracted HTTP(S) links, IPv4/IPv6 addresses and SHA-256 indicators. Telegram link entities take precedence over plain-text detection; indicators are deduplicated and bounded. The action opens a review/selection screen. Only an explicit Look Up sends the chosen indicator, including URL query parameters, to VirusTotal. Other message text is not sent. Secret-chat context actions are excluded.

The native document picker opens one file without copying it into app storage. Hashing uses a background queue, a security-scoped URL, `NSFileCoordinator`, `FileHandle` reads and incremental `CryptoKit.SHA256`. It checks the size before/while reading, rejects directories/packages/symlinks, and checks descriptor/path identity, size and modification metadata after reading. File-provider materialization may occur through the system file provider; no file contents are sent to VirusTotal. Cancelling interrupts coordination and stops reading at a chunk boundary; completion can be delivered while system file-provider cancellation finishes.

After hashing, the user explicitly taps **Look Up SHA-256**. Manual SHA-256 input is also supported. The service validates exactly 64 hexadecimal characters and normalizes letter case.

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
- Idle/request timeout: **45 s**. URLSession resource timeout: **90 s**.
- One HTTP request at a time per client. Shared AI client: at least **1 s** between starts. Shared VirusTotal client: at least **15 s**. Cancellation does not refund this spacing.
- `429` and `503` with `Retry-After` extend backoff. Seconds and HTTP dates are supported; malformed/missing 429 values use 60 s, extreme values are capped at seven days. There are **no automatic retries**.
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
| `geminiUseProxy`, `groqUseProxy` | Unsupported legacy app-proxy flags; not applied and not exposed as working switches |
| `virusTotalEnabled` | Enables hash/URL/IP HTTP lookups; local hashing can be used independently |
| `virusTotalApiKey` | Legacy lookup key and Keychain account name |
| `virusTotalConnectionStatus` | Timestamped string from the current controller's real request outcome; cleared when its key changes |

Networking uses the system's URLSession configuration, including configured system networking. Telegram's MTProto/SOCKS configuration and the recovered private proxy flags are not wired into these HTTP clients. No private proxy or custom endpoint is guessed. Historical saved connection strings are not treated as a current authentication check.

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

`whitegram/tests/services/` contains **56 XCTest methods** against actual production builders, parsers, gates, tasks, conversation persistence and credential policy, plus the actual URLSession transport through an intercepting URLProtocol. Apple hosts additionally exercise incremental file hashing and the redirect delegate.

Run on a Swift-capable host:

```text
python3 -B whitegram/tests/services/run_swift_tests.py
```

The runner copies the eight non-UI production files into an isolated, dependency-free SwiftPM host beneath `tests/services/.host-package`, records their SHA-256 digests, and keeps build/cache/temp artifacts beneath `tests/services/.host-artifacts`. It does not compile a substitute service implementation. It accepts `--swift <executable>` and `--filter <XCTest filter>`.

- macOS: all 56 methods are present, including known SHA-256 vectors, multiple chunk boundaries, oversized sparse files, symlinks, cancellation, stale-conversation revisions, target extraction and real redirect-delegate behavior.
- Linux: request/parsing/credential-policy/task tests and URLSession fixture tests are host-independent. The five CryptoKit/Darwin hash methods are excluded; the redirect test explicitly skips FoundationNetworking's unimplemented URLProtocol redirect callback.
- No tests require real credentials or permit a request to reach a provider. URLSession tests install a URLProtocol that intercepts every URL; the other client tests inject a manual transport.
- The native Security/TelegramCore adapter, settings UI, signing, native picker presentation and actual API access still need the app's Apple build/device verification.

Offline syntax/source-contract check used in this Windows workspace:

```text
C:\Users\Pisun4ik\AppData\Local\Temp\opencode\whitegram-check-env\Scripts\python.exe -B whitegram/tests/services/check_sources.py --target C:\Users\Pisun4ik\AppData\Local\Temp\opencode\whitegram-port-12.9.2
```

This uses tree-sitter 0.25.2 / swift grammar 0.7.3 and checks the target controller signatures/import, endpoint/auth-storage invariants, masked editors and bounded file reads. It is **syntax/static validation, not Swift compilation or runtime verification**. Twelve production and six test Swift files pass this check. The first 49 native tests passed in earlier macOS runs; the new conversation/target cases require the new revision's runner. No actual provider request or device execution is claimed.

## Remaining integration/unsupported features

- Streaming, audio/image/file AI input, Gemini tuned/dynamic resource endpoints, model discovery, provider tool execution and custom HTTP endpoints/proxies.
- VirusTotal upload/reanalysis, automatic attachment scanning, paid intelligence APIs and verdict guarantees. This port fetches existing file/URL/IP reports.
- Original persisted AI-history format migration and service plugin bindings beyond the existing explicit callback APIs.
- UI copy is currently English; recovered localization strings were not invented.

### Official protocol references

- Gemini: <https://ai.google.dev/api/generate-content>; its official REST binding is also in <https://github.com/googleapis/googleapis/blob/master/google/ai/generativelanguage/v1beta/generative_service.proto>.
- Groq: <https://console.groq.com/docs/api-reference#chat-create>.
- VirusTotal: <https://docs.virustotal.com/reference/file-info> and <https://docs.virustotal.com/reference/files>.
