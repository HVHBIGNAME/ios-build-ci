# Whitegram JavaScript plugin runtime

Integrated source installation, menu routing, resource assembly and current verification results are recorded in [PORT_STATUS.md](PORT_STATUS.md).

This addition implements an explicitly started, account-scoped JavaScript plugin manager using JavaScriptCore and native Telegram 12.9.2 APIs. It includes persistent imports, Run/Stop/Delete, source inspection, a live bounded log, per-plugin permissions, JSON/file storage, URLSession HTTP, native UI trees, and Telegram message operations. The manager uses `ItemListNodeEntry.item(presentationData:arguments:)`.

## Parent integration

The assembler copies these six files from `whitegram/cleanroom/` into **`submodules/SettingsUI/Sources/Whitegram/`** in the target:

- `WhitegramPluginManagerController.swift`
- `WhitegramPluginRuntime.swift`
- `WhitegramPluginStorage.swift`
- `WhitegramPluginHTTP.swift`
- `WhitegramPluginTelegram.swift`
- `WhitegramPluginUI.swift`

`SettingsUI` already globs `Sources/**/*.swift`. The public entry point is:

```swift
public func whitegramPluginManagerController(context: AccountContext) -> ViewController
```

The parent menu should call and push that controller **on main** for its Plugins action. No application-start hook is required. Opening the manager loads installation **metadata**; a plugin is evaluated only after the user selects **Run Plugin**. Running sessions survive navigation away from the manager. Account removal stops that account's sessions; returning to the manager reuses the session. An app restart leaves every plugin stopped. A deleting installation cannot be restarted while its asynchronous removal is in flight.

### Exact resources

Bundle **only these six files**, retaining these basenames, from `whitegram/cleanroom/pluginsdk/`:

```text
Telegram.app/WhitegramPluginSDK.bundle/
  Info.plist
  whitegram-native-bootstrap.js
  whitegram-sdk-core.js
  whitegram-plugin-lifecycle.js
  whitegram-sdk-extensions.js
  whitegram-sdk-bridge.js
  whitegram-plugin-host.js
```

The preferred integration is an `apple_resource_bundle` **named `WhitegramPluginSDK`**. For example, after copying the six files into `submodules/SettingsUI/WhitegramPluginSDK/`, add the following targets to that module's BUILD file:

```starlark
load("@build_bazel_rules_apple//apple:resources.bzl", "apple_resource_bundle")
load("//build-system/bazel-utils:plist_fragment.bzl", "plist_fragment")

plist_fragment(
    name = "WhitegramPluginSDKInfoPlist",
    extension = "plist",
    template = """
    <key>CFBundleIdentifier</key>
    <string>org.whitegram.PluginSDK</string>
    <key>CFBundleDevelopmentRegion</key>
    <string>en</string>
    <key>CFBundleName</key>
    <string>WhitegramPluginSDK</string>
    """,
)

apple_resource_bundle(
    name = "WhitegramPluginSDK",
    infoplists = [":WhitegramPluginSDKInfoPlist"],
    resources = [
        "WhitegramPluginSDK/whitegram-native-bootstrap.js",
        "WhitegramPluginSDK/whitegram-sdk-core.js",
        "WhitegramPluginSDK/whitegram-plugin-lifecycle.js",
        "WhitegramPluginSDK/whitegram-sdk-extensions.js",
        "WhitegramPluginSDK/whitegram-sdk-bridge.js",
        "WhitegramPluginSDK/whitegram-plugin-host.js",
    ],
    visibility = ["//visibility:public"],
)
```

Add **`//submodules/SettingsUI:WhitegramPluginSDK` to `Telegram/BUILD`'s `ios_application(name = "Telegram", resources = [...])`** so the bundle is at the application root. Placing it only inside `TelegramUIFramework.framework` will not satisfy this loader. The loader also accepts the same six basenames directly under `Telegram.app/WhitegramPluginSDK/` when the parent already emits a structured resource directory.

**Do not bundle/evaluate `whitegram-sdk-hooks.js` as JavaScript.** The recovered file is a truncated chat-export HTML fragment, beginning with a closing title tag. Language workers, their HTML host, and the TypeScript transpiler are not runtime dependencies here.

Load order is fixed in `WhitegramPluginRuntime.resources`:

1. New native bootstrap: JSON-only native transport and base `wg` contracts.
2. Recovered `whitegram-sdk-core.js`: UI normalization/state/dispatch and helpers.
3. Recovered `whitegram-plugin-lifecycle.js`: BasePlugin and compatibility names.
4. Recovered `whitegram-sdk-extensions.js`: manifest methods, bytes, state and events.
5. `__wgInstallNativeCompatibility()`: targeted adapter repairs described below.
6. Recovered `whitegram-sdk-bridge.js`: permission wrapping.
7. The explicitly imported entry, then `__wgFinishEntry()`.
8. On stop: prepare cancellation, recovered `whitegram-plugin-host.js` for `onUnload`, then release the context.

### Exact module dependencies

These `SettingsUI.deps` entries are required and are already present in the inspected 12.9.2 target:

```starlark
"//submodules/SSignalKit/SwiftSignalKit:SwiftSignalKit",
"//submodules/AsyncDisplayKit:AsyncDisplayKit",
"//submodules/Display:Display",
"//submodules/Postbox:Postbox",
"//submodules/TelegramCore:TelegramCore",
"//submodules/TelegramPresentationData:TelegramPresentationData",
"//submodules/ItemListUI:ItemListUI",
"//submodules/AccountContext:AccountContext",
```

System-framework imports are **JavaScriptCore**, **UniformTypeIdentifiers**, **CoreFoundation**, Foundation and UIKit. Swift autolinks these SDK frameworks; there is no new third-party Bazel module dependency. The modern document-picker initializer is guarded by iOS 14 availability, with the legacy import initializer on iOS 13. No WebKit, worker engine, or Telegram authentication object is exported into JavaScript.

The implementation reads/writes the parent's public `TelegramCore.WhitegramPreferences`. It does not provide a second copy of that type.

## Import format and persistence

Import either a UTF-8 **`.js`** file or a **`.wgplugin` / `.json` JSON package**. A plain script is stored as `main.js`; its initial display name is the selected filename. A JSON package has this format:

```json
{
  "name": "Example Plugin",
  "version": "1.0",
  "runtime": "javascript",
  "entry": "main.js",
  "permissions": ["storage", "uiMutation", "network"],
  "files": {
    "main.js": "const config = require('./config.json'); console.log(config);",
    "config.json": "{\"enabled\":true}",
    "assets/icon.png": { "base64": "...valid base64 image bytes..." }
  }
}
```

`main` is accepted as an alias for `entry`. ZIP archives, directory imports, `.ts` entry scripts, and arbitrary recovered package formats are not accepted. This JSON format is a cleanroom transport format, not a claim of original ZIP-package compatibility. Imports validate structure, encoding, permissions and quotas; JavaScript syntax is checked by evaluation when Run is selected. Importing a file does not execute it.

Each installation receives a fresh UUID. Packages and data are stored under:

```text
Application Support/WhitegramPlugins/v1/<account-record-id>/<installation-uuid>/
  manifest.json
  package/                  # immutable through the plugin API
  data/state.json           # wg.storage
  data/files/               # wg.fs
```

Entries may explicitly `require()` other **JS or JSON** files in their own package. Resolution supports exact paths, `.js`, `.json`, `/index.js`, and `/index.json`, CommonJS cycles and caching. Failed evaluations and failed JSON parses are evicted. `require("wg")` and `require("whitegram")` return the current scoped API. There is no Node filesystem, npm resolution, implicit folder scanning/evaluation, or network module loading.

Path checks reject absolute paths, drive/URL prefixes, backslashes, controls/NUL, empty/dot components, symlinks, and paths escaping the root. Package/data directories are revalidated from the installation root on each operation, including after a session has opened them. Relative module `../` is allowed only when it stays within the package. URL-escaped components are literal filenames and are not decoded. Import paths that collide by case/canonical Unicode normalization or use a file as a directory are rejected. JSON writes and file replacements are atomic. Imports are built under an unlisted `.install-<uuid>` staging directory and renamed into the installed namespace only after their manifest and files have been written. Reads use a bounded file handle even if a selected document grows after its size check.

## Permissions

The recovered `__wgPermissionGate(permission, path)` / `__wgPermissionTable` contract is used. Native entry points **also** enforce permissions, including direct `wg.__native` and SDK-registry calls; replacing JavaScript's gate cannot grant native access.

| ID | Access | Initially granted |
| --- | --- | --- |
| `storage` | Own package reads, own JSON and writable files | Yes |
| `uiMutation` | Plugin screens, dialogs, toasts, theme and haptics | Yes |
| `account` | `getMe`, `tg.myId` | No |
| `messages` | Chat list/history/peers, watches and message operations | No |
| `media` | Send a file from this plugin's files/package | No |
| `network` | Independent HTTP requests | No |
| `settings` | Shared Whitegram preferences | No |
| `clipboard` | System clipboard reads/writes | No |

The first seven IDs use recovered legacy permission names; `clipboard` is a port-specific permission. Declared package permissions are displayed, not automatically granted. Change permissions in the plugin detail screen, then run the script. Changing a permission stops the current session. `wg.permissions.has(id)` checks a grant without prompting. Unknown declared permission IDs reject import.

Decisions are stored through `WhitegramPreferences` under `pluginRuntime.permissions.<account-record-id>.<installation-uuid>` inside the existing `WhitegramSettingsState.v1` store. Plugin `preferences` APIs cannot read/write `pluginRuntime.*`; they cannot grant permissions to themselves or other plugins. File sending additionally requires `messages` and `storage`; opening a Telegram chat additionally requires `uiMutation`.

## Implemented JavaScript APIs

### Execution and storage

- `console.log/info/debug/warn/error`, `wg.log`, `wg.logLevel` — real manager log entries.
- `setTimeout`, `setInterval`, matching clear functions, the `wg.*` timer names, and cancellable `wg.sleep(ms)`. Timers accept functions; globals support additional arguments.
- `wg.BasePlugin`, `wg.registerPlugin(instance)`, `module.exports = instance`, or an exported constructor. An exported lifecycle object is registered once without rewriting its methods; frozen objects work. Promise-returning `onLoad`, including plugins registered during another awaited `onLoad`, is awaited. Its rejection fails startup and cleans up the session.
- `wg.storage.get(key, fallback?)`, `set(key, json)`, `remove(key)`, `keys()`, `clear()` — synchronous, plugin-scoped JSON persistence.
- `wg.files.list()`, `read(path)`, `readBase64(path)` — synchronous package reads. Missing files return `null`.
- `wg.fs.list(directory?)`, `exists(path)`, `read/readBase64/readBytes(path)`, `write/writeBase64/writeBytes(path, data)`, `remove(path)` — synchronous writable plugin files. Reads of absent files return `null`; removing an absent file returns `false`.
- `wg.bytes.from/toString`, `wg.util.base64ToBytes/bytesToBase64`, SDK byte-token transfer. Use `Uint8Array` for binary arguments; the recovered packer is not guaranteed to preserve offsets of other typed-array/DataView types. Byte tokens are consumed and bounded. Failed high-level argument packing, return-value revival and event revival release temporary tokens; revival errors reject registry Promises.
- `wg.state` / `wg.createStore`: get/set, batching, watch, computed, snapshots and persistence from the recovered extension.
- `wg.preferences.get(key, fallback?)`, `set(key, json)`, `values()` — the shared Whitegram preference source, excluding runtime-private keys.
- `wg.clipboard.get()` / `set(text)` — main-thread UIKit calls.
- `wg.capabilities.has/info/feature/version/iosAtLeast` and installed-language checks. `has()` is based on supported methods, not the mere existence of an unsupported wrapper. No invented Telegram API layer is advertised.

### HTTP

`wg.request(options, callback?)` and `wg.http.request(options)` use an independent, ephemeral `URLSession`. Options: `url`, `method` (GET/HEAD/POST/PUT/PATCH/DELETE/OPTIONS), string `headers`, `body` (UTF-8 string or JSON), `bodyBase64`, and `timeout` in **seconds** (1–60). The registry API also supports packed `Uint8Array` bodies.

Results contain `{ok, status, url, headers, body, base64, elapsedMs}`. `body` is `null` for non-UTF-8 data. HTTP 4xx/5xx are real responses with `ok:false`; transport, validation, cancellation and quota failures reject. `wg.request` callbacks receive `(error, response)`.

- `wg.fetch(url, callback?)` / `fetchJSON` return text / parsed JSON and reject non-2xx statuses, invalid UTF-8 and JSON errors. Callbacks receive `(error, body)`.
- `wg.fetchPost(url, body, headers?, callback?)` / `fetchPostJSON` provide the corresponding POST adapters.
- `wg.httpGet(url, callback?)` / `httpPost(url, body, callback?)` preserve the recovered **single response-object callback** contract, now with actual HTTP status. Transport errors call back `{ok:false, error, status:0, body:null}` and reject the returned Promise.
- `wg.net.httpTiming(url, callback?)` performs a real HEAD request and reports the same response/elapsed time; it does not claim DNS/TLS phase timings.

There is no Telegram network/MTProto session, cookie jar, shared URL cache or credential storage in this client. Embedded URL credentials and non-HTTP(S) URLs are rejected. Authorization/Cookie headers are stripped on cross-origin redirects. Both session-level and task-level authentication challenges use default system server-trust validation and cancel other challenge types; cancelled authentication challenges surface as transport errors rather than a synthetic HTTP response. Requests respect the application's existing ATS policy. Malformed method/timeout/body/header options reject rather than silently changing the request; empty-body `fetchPost` calls still use POST.

### Telegram

`wg.tg.*` registry methods return Promises, except synchronous `tg.myId()`. Legacy root methods return a Promise and also accept a last callback `(result, error)`; failed operations use `result:null`. The recovered `wg.client` wrappers remain connected to these root methods. Permission wrappers can throw synchronously before a Promise is returned, as in the recovered SDK.

| Operation | Native implementation / result |
| --- | --- |
| `getMe()` | `engine.data.get(Peer.Peer(id: account.peerId))`; profile dictionary |
| `getPeer(peerId)` | Engine peer lookup; `@username` uses `engine.peers.resolvePeerByName` |
| `getChatList(limit=50)` | `engine.messages.chatList(group:.root,count:)`, first snapshot |
| `getMessages(peerId,limit=50,offsetId=0)` | Bounded **local cached cloud history**, newest first; IDs strictly below a nonzero offset |
| `tg.getMessage(peerId,messageId)` | `engine.messages.downloadMessage`, allowing a known cloud message to be loaded |
| `sendTextMessage(peerId,text)` | Real `enqueueMessages` |
| `reply(peerId,messageId,text)` / `tg.reply` | Real `EngineMessageReplySubject`; reply ID is retained |
| `sendFileMessage(peerId,path,caption?,mimeType?)` | Plugin-owned data copied to a real `LocalFileMediaResource`, then enqueued |
| `sendDiceMessage(peerId,emoji)` | `TelegramMediaDice`, then enqueued; standard six dice emoji |
| `sendLocationMessage(peerId,lat,lon)` | `TelegramMediaMap`, then enqueued |
| `sendContactMessage(peerId,first,last,phone)` | `TelegramMediaContact`, then enqueued |
| `forwardMessage(fromPeerId,messageId,toPeerId)` | `.forward` enqueue |
| `editMessage(peerId,messageId,text)` | `requestEditMessage(... media:.keep, richText:nil, inlineStickers:[:])`; waits for `.done` / error |
| `deleteMessage(peerId,messageId,forEveryone=false)` | `deleteMessagesInteractively` |
| `pinMessage(peerId,messageId,pinned)` | `requestUpdatePinnedMessage`, pin/clear |
| `reactToMessage(peerId,messageId,emoji)` | `updateMessageReactionsInteractively`; empty emoji clears; message must be loaded |
| `markChatAsRead(peerId)` | Highest cached cloud index -> `applyMaxReadIndexInteractively`; no cached message yields `NO_RESULT` |
| `openChat(peerId)` | Main-thread `sharedContext.navigateToChat`; returns `{requested:true}` |

Enqueue results are **`{queued:true,messageIds:[{peerId,id,namespace}]}`**, using Telegram's actual local IDs. They do not assert server delivery. Pending IDs must not be treated as cloud message IDs. Delete/reaction/read operations report local queue acceptance; edit/pin report completion of their engine request. Stopping a plugin cannot recall messages already enqueued in Telegram.

Peer IDs are **strings**, as returned by this bridge (Postbox packed Int64 representation). Explicit `user:123`, `group:123`, `channel:123`, and `me`/`self` are also accepted. Bot API `-100...` IDs are not inferred. Explicit message IDs are positive cloud Int32 IDs. Secret chats, community-specific operations, forum/topic routing, rich-text entities and paid-message flows are not implemented. Chat lists can describe such peers, but unsupported peer namespaces reject operations. Message objects include text/date/author/outgoing/pending/thread ID and basic media metadata, not auth keys, access hashes or media bytes.

`wg.invoke("client.…", params, callback?)` covers the implemented operations above, including `client.getMessage` and `client.reply`. It retains the recovered `msgId` alias for `messageId` and waits for results/errors instead of reporting success immediately. Raw MTProto and unknown actions reject explicitly.

Native signatures were cross-checked against the full `whitegram-port-12.9.2` source: `EngineRawMessage`, `EngineRawMedia`, `EnginePeer.Id`, `EngineMessage.Id/Index`, `EngineHistoryViewInputAnchor`, the engine message methods, Postbox history views and media constructors. In particular, cached history uses `[EngineRawMessage]`, avoiding the unrelated exported FlatBuffers `Message<T>` name. Message resources are stored through MediaBox's asynchronous data queue.

### Events and watches

- `wg.on/off`, recovered `wg.events.on/once/off/emit/sticky/stream` with wildcard patterns. Custom emitted names must start with `plugin.` and are **local to this plugin**, not an inter-plugin bus.
- Native events: `app.foreground`, `app.background`, `app.screenshot`, `theme.changed`, and `settings.changed` (the last requires `settings`). Lifecycle aliases `onAppForeground`, `onAppBackground`, `onScreenshot`, `onThemeChange` are connected.
- `await wg.chat.watchMessages(peerId, callback, limit=50)` subscribes to that peer's Postbox cloud-history view and returns `{id,close()}`. Callbacks receive `{peerId,messages,scope:"local",initial}` snapshots. The initial snapshot can arrive while subscription setup is completing. This is not a global incoming-message hook or a server-history backfill.
- Streams implement `Symbol.asyncIterator`, close pending `next()` on stop, and retain at most 256 undrained events (oldest dropped). Separate registrations of the same function have independent IDs.
- Removing another event pattern inside a callback does not invalidate the current delivery snapshot or abort later delivery.

### Native UI

`wg.ui.window/panel/sheet/screen`, `wg.screens.push/present`, surface `update/setState/setTitle/set/show/hide/close/info`, `ui.surfaces/closeAll`, theme, keyboard height, haptics, toast/action-toast, confirm, menu and prompt are connected. Surface creation is synchronous: a returned ID belongs to an allocated and validated native controller. Unknown nodes and unavailable presentation contexts throw errors.

Supported elements: VStack, HStack, Card, Glass/Blur (UIKit materials), Section, List/Scroll, Text, Button/Row, Toggle, Slider, Stepper, TextField, TextArea, Segmented, Progress, Spinner, Spacer, Divider, Icon and Image. TextField/TextArea `id` or `bind` preserves focus on rerender; `bind` and `rerender:false` use the recovered state contract. Segmented options are strings and its value is an index. Images come from the plugin package or base64 image data URLs; there is no implicit remote image fetch. Icons use SF Symbol names.

Windows/panels/sheets use Telegram's navigation-modal presentation; screens are created hidden until pushed/shown. These are not draggable floating windows. There is one outer scrolling container; nested List/Scroll nodes form vertical content. Live option changes currently apply the title. Styling supports spacing, padding, text size/weight/color/alignment, enabled/hidden and the documented control values; arbitrary original window/layout/material options are not fully reproduced. Web/HTML, ZStack layering, overlays, tabs, chat/header buttons and native UI injection slots reject explicitly.

UI callback tokens are dispatched on the JS queue; UIKit never retains JSValue callbacks. Rerender discards stale callbacks. If a replacement tree fails native validation, its surface closes because the recovered core has already invalidated the previous callback map. Async callbacks supplied through creation, `surface.update`, `surface.set` and prompts log rejections. Toast expiration frees its action without firing it. Confirm success callbacks receive one boolean; menu success callbacks receive `(index, title)`, preserving the recovered contracts. Other application-created promises should be awaited or given `.catch(console.error)`; JavaScriptCore does not supply the browser's global unhandled-rejection event.

## Lifecycle, limits and unsupported areas

Each plugin has a serial JS queue and a separate JSContext/VM. UIKit runs on main; main never synchronously waits for a JS queue. Synchronous native UI calls hop to main only from JS. Async calls use JSON and bounded request tokens; no AccountContext, UIKit object, Telegram session or retained JSValue callback crosses the bridge.

Stop immediately revokes the native session, cancels timers, HTTP and Signal subscriptions, and closes native UI. Repeated Stop calls share one queued teardown and complete after it finishes. On the owning JS queue it rejects pending requests/sleeps, ends streams, marks surface handles closed, calls recovered `onUnload`, clears callbacks and releases the context. `onUnload` supports synchronous logging and own `wg.storage` reads/writes; starting new async work during unload fails. Async `onUnload` is not awaited. Startup's async `onLoad` has a 30-second cooperative deadline; ordinary native requests have a 65-second outer deadline and dialogs 120 seconds. Each request also has a cancellation lifetime: expired work is rejected before starting a queued main-thread operation or Telegram mutation, and dialog cancellation dismisses only the dialog belonging to that request.

**A non-yielding JavaScript loop cannot be forcibly interrupted with the public JavaScriptCore APIs used here.** Stop still disables native operations and closes UI, but its queued JS teardown cannot finish until that script yields. Such a session stays stopping; an app restart is needed for a permanently looping script. Node's test VM timeout is not a production watchdog. This is an imported-code capability boundary, not a hard CPU/heap sandbox. iOS suspension is respected; timers/jobs do not promise background execution.

Bounds: eight running plugins/account, eight surfaces/plugin, four visible toasts/plugin, eight watched peers/plugin, 256 timers (interval minimum 16 ms), 128 pending native requests, 16 simultaneous HTTP tasks, 256 event handlers per event API, 64 streams and 64 sticky events. Transfers/files/HTTP bodies and responses are capped at 2 MiB; byte-token storage at 4 MiB/32 tokens; a decoded package at 8 MiB/256 files and its import document at 12 MiB; writable files at 16 MiB/256 files; JSON state at 2 MiB. Paths have at most 32 components and 1024 UTF-8 bytes. Logs retain 200 entries/plugin, up to 8 KiB/entry and 100 entries/second, in memory for the manager session.

Explicitly unsupported: global Telegram send/receive/request/update overrides; arbitrary postbox transactions; raw MTProto; interceptors and deferred hooks; inter-plugin services; durable/background jobs; chat/menu/settings-row injection; live current-chat discovery; TCP/UDP/DNS/WebSocket tools; download/upload convenience APIs; external filesystem access; browser DOM/Worker APIs; Python/Lua/Ruby/Go runtimes; TypeScript compilation; and `wg.wasm` execution. Unsupported registry/namespace calls raise `UNSUPPORTED_API` (or a specific unsupported UI/language error). Capability discovery does not count their throwing wrappers as implementations.

The bootstrap repairs known recovered-JS compatibility issues without editing recovered files: hard-coded HTTP 200, discarded reply IDs, immediate-success `invoke` mutations, nonrejecting dialog adapters, missing stream iterators, cached failed modules, function-form surfaces, reused-handler IDs, async callback logging and toast callback cleanup. The resumed review additionally fixed frozen/nested lifecycle registration, `msgId`/menu-title contracts, failed byte-pack/revival cleanup, event unsubscription during delivery, empty POSTs and replacement-surface callback ownership.

## Verification

Run from the build repository root:

```powershell
node --test "whitegram/tests/plugins/bootstrap.test.cjs"
& "C:\Users\Pisun4ik\AppData\Local\Temp\opencode\whitegram-check-env\Scripts\python.exe" -B "whitegram/tests/plugins/check_swift_syntax.py"
```

The Node suite loads the **actual recovered core/extensions/lifecycle/permission bridge** and new bootstrap. Its JSON host fixture consumes the native Swift resource/registry declarations and exercises load order, lifecycle, cancellation, errors, permissions, module/path contracts, UI callbacks, bytes/persistence, events and the shipped Notes example. **36 tests passed** after this review. Fourteen additional Telegram client/registry argument paths are exercised within the native-contract test. Native Telegram/UIKit/URLSession/Postbox behavior is represented by explicit fixtures; Node results are not evidence of device execution or native path/symlink enforcement.

The supplied XCTest files exercise actual Foundation code:

- `WhitegramPluginStorageTests.swift`: **9 cases** covering containment/symlinks, replaced roots, internal module parents, persistent JSON/files, invalid state/quotas, non-evaluating imports, canonical/file-directory collisions, bounded reads, and strict JSON boolean/number handling.
- `WhitegramPluginHTTPTests.swift`: **4 cases** covering request construction without implicit auth/cookies, JSON/base64 bodies and timeouts, invalid URLs/options/headers/quotas, and cross-origin credential stripping.

Run them in a SettingsUI-linked Apple XCTest host with `-enable-testing`. These **13 native XCTest cases have not been executed** in the Windows environment.

`check_swift_syntax.py` checks the six implementation files plus both XCTest sources: **8 files parsed successfully** with tree-sitter 0.25.2 / tree-sitter-swift 0.7.3. It refuses other version pairs before loading the parser (0.26 is known to crash here). Syntax parsing is not type checking, linking, a Bazel build or simulator/device validation. The referenced Telegram signatures were inspected in the assembled 12.9.2 source. There is no local Xcode/Swift compiler; an Apple build and device smoke test remain necessary for integration validation.

For a hands-on smoke test, import `whitegram/tests/plugins/example-notes.js`. It creates a real SDK-driven native Notes sheet and persists edits using `storage`; sending to Saved Messages requires enabling `account` and `messages` and tapping its Send button.

On device, also confirm Stop during a pending HTTP request/dialog/watch, rapid Stop/Run/Delete actions, rejected permission calls, persistence across relaunch, and the absence of callbacks after teardown. These native lifecycle/presentation scenarios were reviewed in source, not executed by the Node fixture.
