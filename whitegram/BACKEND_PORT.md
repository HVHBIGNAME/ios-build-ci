# Backend handoff — recovered 3.1.1 / Telegram 12.9.2 (71)

The backend-owned source is coherent for integration. The Windows checks cover source composition, Swift parsing and independently recovered protocol constants. Native XCTest, iOS compilation, authenticated server acceptance and device behavior have **not** run.

## Installation and patch API

`backend_patches.BACKEND_RUNTIME_FILES` is the explicit filename-to-destination registry for 32 sources. `traffic_patches.TRAFFIC_RUNTIME_FILES` contains the other three sources. Their complete combined map is in `parity/backend.json`. Only `WhitegramBackendMessageEvent.swift` and `WhitegramBackendMessageBridge.swift` belong to TelegramCore; the other 33 sources belong to SettingsUI.

The parent owns installation, BUILD changes and routes. Apply `apply_backend_patches(root)` and `apply_traffic_patches(root)` after the baseline overlay. Both also expose a staging API accepting `SourcePatches`: `backend_patches(patches)` and `traffic_patches(patches)`. Do not invoke writing wrappers on the read-only reference.

The patches install startup/account registration in `TelegramUI/Sources/AppDelegate.swift`, incoming confirmed-message observation in `TelegramCore/Sources/State/AccountStateManager.swift`, and single/group send acknowledgement observation in `TelegramCore/Sources/State/ApplyUpdateMessage.swift`. They preserve Telegram's message updates and transport. The shared installer order, both relative backend/traffic orders and replay were checked in memory against `C:/coding/telegram/whitegram/source-12.9.2`.

## Account-bound public transport

Defined in `WhitegramBackendTransport.swift`, exported from SettingsUI:

```swift
WhitegramBackendAuthorizedTransport(userId: Int64)
transport.hasSession() throws -> Bool
transport.accessState -> WhitegramBackendAccessState
transport.refreshAccess(completion:) -> WhitegramBackendTask
transport.disconnect() throws

transport.execute(
    path: String, query: [URLQueryItem] = [], method: String = "GET",
    providerKey: String? = nil, body: Data? = nil, bodyFile: URL? = nil,
    contentType: String? = nil, accept: String = "application/json",
    maximumResponseBytes: Int = 8 * 1024 * 1024,
    received: ((Data) throws -> Void)? = nil,
    progress: ((Int64, Int64) -> Void)? = nil,
    completion: @escaping (Result<WhitegramBackendHTTPResponse, WhitegramBackendError>) -> Void
) -> WhitegramBackendTask
```

- Pass the **Telegram CloudUser numeric ID**, not AccountRecordId or a channel ID. There is no mutable current-account fallback.
- `WhitegramBackendAuthorizedTransport.baseURL` exposes the recovered fixed origin. Requests accept paths and separate query items, never an arbitrary destination URL.
- `X-Provider-Key` is accepted only beneath `/v1/proxy/`. The caller supplies its recovered provider path; this module does not guess provider-specific paths or fall back to a direct provider.
- All callbacks are serial on the main queue. Successful HTTP responses, including non-2xx status codes, retain `response`, `data` and `duration`. Inspect `response.statusCode`; a transport `.success` is **not** provider/application success.
- `received` sees incremental 2xx chunks; non-2xx error bodies are retained for completion instead. Throwing aborts the transfer. A non-backend consumer error becomes `invalidResponse`.
- `body` and `bodyFile` are exclusive. Upload files must be regular files and are capped at 512 MiB + 4096 bytes. The caller owns and keeps the file unchanged until completion, including after cancellation. URLSession completion follows termination of the file reader.
- Responses are capped at 8 MiB; callers can request a lower bound. Redirects are refused. Ephemeral sessions disable cookies, credential persistence and URL caching; system trust plus the original SPKI pin set are required.
- Session/access changes cancel in-flight authorized tasks and are rechecked before headers, chunks, progress and completion. Nonproxy 401 removes only the matching account/session. Provider 401 remains a provider response and does not destroy a Whitegram session. Retry-After creates account/client/path backoff; a subsequent call can fail locally with `http(429, retryAfter:)`.

Authentication is `WhitegramBackendAuthentication(context:)`. Retain it, call `connect(completion:)` and `cancel()` on the main thread. It obtains the original auth bot, requests Telegram's simple web view, extracts init data once, exchanges a session and verifies beta access. Cancellation suppresses obsolete auth callbacks. `transport.execute` cancellation, in contrast, completes with a cancellation error. Authentication success requires verified allowed access; a denied/unknown verdict is not turned into success.

Public observation: `whitegramBackendSessionUpdated`, `whitegramBackendAccessUpdated` (both include `userInfo["userId"]`), and `whitegramBackendAccessState(userId:)`. The parent can use these for its menu/access state machine. Backend startup registration currently covers the primary account; parent account lifecycle code can also call `whitegramRegisterBackendAccount(userId:)` for other active accounts. Call `disconnect()` when intentionally removing that account's backend credentials.

`WhitegramServiceProxy.swift` now adapts this contract for the account-bound Gemini, Groq and VirusTotal clients. It is installed by `SERVICES_RUNTIME_FILES`, not `BACKEND_RUNTIME_FILES`. The native service screens use CloudUser IDs and the backend authentication/access APIs. See [SERVICES_PORT.md](SERVICES_PORT.md) for provider paths, upload URL restrictions and the optional account parameter on service callbacks. Integration fixtures are in `tests/backend/WhitegramServiceProxyTests.swift`; they use the production adapter with synthetic sessions and intercepted HTTP.

## Original evidence and trust

The audit IPA SHA-256 is `bd6d3a13046d5857c1389e2d794c4c2ca44cee89bb22880004bd77f84fe29837`. `tests/backend/protocol-evidence.json` records addresses and synthetic signing vectors. `tests/backend/verify_original.py` independently reopens and hashes the original IPA using its read-only audit/tooling.

- Image 46 `0x2d7f24` and `0x2daf44` decode the API root `https://api.whitegram.heypainservice.online`; `whitegram.click` is not used as a guessed API root.
- Image 46 `0x2da040` signs `unixSeconds:UPPERCASE_METHOD:path[?query]` with application HMAC-SHA256, P256 device signing and the optional session HMAC. Authorization is `Whitegram <token>`.
- The application signing key is private build configuration, not a repository constant. `postprocess.py` reads canonical 32-byte base64 from `WHITEGRAM_BACKEND_APPLICATION_KEY` and places it in the main app's Info.plist. CI supplies it through the repository Actions secret of that name. Missing/invalid runtime configuration fails explicitly; offline signing vectors use an unrelated synthetic key.
- Image 46 `0x2d9a04` contains the four pinned SPKI hashes; the P256/P384 DER prefixes were checked independently.
- Image 55 `0x55b528` verifies the original Ed25519 beta key. Image 46 `0x217fa0` defines `whitegram.beta.status.v1|userId|allowedAs0Or1|issuedAt|expiresAt|nonce`. Fresh 32-hex nonce, account identity, expiry, 120-second future skew and a maximum 600-second signed lifetime are checked. The original cache bounds are 900 seconds positive and 30 negative; this client additionally caps cached grants at signed expiry.
- Image 55 `0x55b888` returns unknown for an absent/invalid signed server verdict. Although local channel-query code exists, this gate does not promote it to an allowed verdict. Unknown and denied remain separate.
- The original device P256 tag is preserved. The original stable device-token Keychain service/account are read before falling back to the old preference or generating a token.

## Data and UI adapters

Working source adapters include profile about/quote/lyrics, lyric lookup and four-line selection, badge settings, scene selection, reactions, wall posting/editing/deletion/blocking, photo slots 0–2, public photo wallpaper, registration dates and streak lists/settings/events. Server responses are validated, stale in-flight profile fetches cannot repopulate caches after a successful mutation, and cached responses recheck account/session/access.

Local wallpaper uses the original `Documents/WallpapersProfile/my_wall_<userId>.jpg`. Choosing a local image does not publish it. Public upload/deletion changes the saved account-specific publication preference only after HTTP success. `whitegramProfileLocalWallpaperData(userId:)` and `whitegramProfilePhotoWallUpdated` are available for the parent's profile rendering integration. A saved publication preference is labeled as saved state, not fresh server confirmation.

Streak hooks exclude bots, self chats, secret media, unsent/failed/non-cloud messages and non-user peers. The event contains only account/peer/message IDs, timestamp and direction. The server payload is peer ID, original event timestamp and the timezone's offset **at that timestamp**. Settings synchronize before events; failed work stays bounded in memory and disabling clears the queue. Streak days/flame levels come from responses, never simulated local achievements.

Radio retains the five recovered stations, EMG WebSocket/ICY metadata, Telegram-managed audio activation/deactivation, remote commands, route-change pause, actual AVPlayer state, listener errors and precise/coarse radio presence. Stop/restart heartbeat requests are serialized. Public audio availability does not establish backend authorization or listener availability.

Improved traffic implements the recovered 60–180-second foreground GET/HEAD scheduler, eight public endpoints and user agents. It stops on disable/background/Low Power Mode/low battery and bounds each response. It does not alter MTProto cryptography or claim censorship resistance was tested.

Scammer refresh in this audited build is a single `RET` at image 46 `0x1f0008`. The source parses the original saved list and distinguishes unavailable/corrupt/listed/not-listed states through `whitegramScammerAssessment(userId:)`. The profile warning uses recovered localization. Embedded snapshot URL/key constants are not proof of an active fetch or a current signed dataset.

## Storage and parent schema requirements

- Existing canonical defaults remain false: `antiCensorshipEnabled`, `whitegramStreakEnabled`, `whitegramPresenceEnabled`, `whitegramPresencePreciseEnabled`, `scammerProtection`, `showRegistrationDateCard`.
- Profile server-owned booleans/text are not mirrored into generic generated settings as if a local change had published them. Route these controls to their service-backed controllers.
- Sessions: new account-specific Keychain service `com.whitegram.backend.sessions.v1`, account `session.<userId>`. Original `wg_apiSessionToken_<id>`, `wg_apiSessionExpires_<id>` and `wg_apiSessionKey_<id>` migrate only after save/read-back equality. Expired, malformed or failed imports are retained.
- Device identity tag: `com.whitegram.deviceIdentity.p256`. Legacy token service/account: `com.whitegram.deviceToken` / `wg_stableDeviceToken`; source is retained. The new vault caches it as `device-token`.
- Wallpaper publication key is the original `wg_profilePhotoWallPublic_<userId>`, not the app-wide generated `profilePhotoWallPublic` boolean. Archive import must not trigger publication/deletion.
- `WhitegramBackend.RequestCounts.v1` stores bounded local daily path counts; it is installation-local diagnostics, not server billing/account eligibility. Scammer keys are read-only `wg_scammerRemoteIdsV1` and `wg_scammerRemoteIdsV1Timestamp`.
- Beta verdicts, profile caches, request throttles and pending streak work are memory-only. No imported preference can grant beta access.

## Remaining checks and parity gaps

1. Run `tests/backend/run_native.py` on macOS (32 copied production files, including service/proxy dependencies and 13 additional proxy integration XCTest methods). Its Windows path exits with an explicit unsupported-platform result. Then compile SettingsUI/TelegramCore/TelegramUI with the parent's actual iOS build; parsing is not type checking.
2. Authenticated historical service access is unavailable here. Test bot authorization, signatures/pins, entitlement, JSON payload acceptance, mutation permissions, provider SSE/file upload, Retry-After, logout/cancellation and reconnect on a device/account authorized to use that service. No live request with account data was sent.
3. The owned controllers are functional form/list adapters, not a verified visual clone of every original inline peer-profile card, rich-text editor, quote/lyric animation, particle scene, badge/flame overlay or photo strip. `showMutualContactsCard`, custom-color/native message-style application and other-user style/badge hiding do not have complete renderer consumers in this handoff. Keep those capabilities qualified; the parent owns route/composition integration.
4. The current photo normalization (1600-pixel thumbnail/JPEG 0.85), radio interruptions/background behavior, source localization coverage and profile layouts still need native/original-device comparisons. Original station reachability and historical remote content/registration/scammer datasets cannot be inferred from an IPA.

See `parity/backend.json` for exact maps, entrypoints and the final command results.
