# Whitegram JavaScript plugin runtime

Integrated source installation, menu routing, resource assembly and current verification results are recorded in [PORT_STATUS.md](PORT_STATUS.md).

This addition implements an explicitly started, account-scoped JavaScript plugin manager using JavaScriptCore and native Telegram 12.9.2 APIs. It includes persistent imports, Run/Stop/Delete, source inspection, a live bounded log, per-plugin permissions, JSON/file storage, URLSession HTTP, native UI trees, Telegram message operations, observational Telegram hooks, and dynamically registered settings pages/rows. The manager uses `ItemListNodeEntry.item(presentationData:arguments:)`.

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

### Required integration for the event/settings slice

The new runtime references **two additional sources in TelegramCore**, exported by `plugin_hook_patches.PLUGIN_HOOK_RUNTIME_FILES`:

| Cleanroom file | Destination |
| --- | --- |
| `WhitegramPluginEventHub.swift` | `submodules/TelegramCore/Sources/WhitegramPluginEventHub.swift` |
| `WhitegramPluginHooks.swift` | `submodules/TelegramCore/Sources/WhitegramPluginHooks.swift` |

The parent must make these three edits in `compat-12.9.4.py`:

```python
# With the other patch-module imports:
from plugin_hook_patches import PLUGIN_HOOK_RUNTIME_FILES, apply_plugin_hook_patches

# After constructing cleanroom_files, before validating/copying its entries:
cleanroom_files.update({
    "cleanroom/" + name: destination
    for name, destination in PLUGIN_HOOK_RUNTIME_FILES.items()
})

# Immediately after apply_history_patches(source_root):
apply_plugin_hook_patches(source_root)
```

`plugin_hook_patches.py` stages **16 hook callsites in six files** using exact, counted `SourcePatches` anchors. It supports the inspected assembled 12.9.2 tree pinned at **`6ad963e5b6`**, including the history overlay. Reapplying the plugin and history capture patches, in either order, produces identical source. Missing/ambiguous anchors fail before this module writes any source. The shared assembler was left for the parent to integrate; merely copying the SettingsUI runtime is insufficient.

TelegramCore's existing `Sources/**/*.swift` glob and Postbox/SwiftSignalKit dependencies cover both files. SettingsUI consumes the public event subscription type through its existing TelegramCore dependency. The ChatController callsites also use TelegramCore directly. **There is no TelegramCore → SettingsUI dependency.** The existing six JS resource names/load order are sufficient; all added JavaScript lives in the separate native bootstrap.

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
| `uiMutation` | Plugin screens, settings-page/row registration, dialogs, toasts, theme and haptics | Yes |
| `account` | `getMe`, `tg.myId` | No |
| `messages` | Chat list/history/peers, watches, native events, current-chat snapshots and message operations | No |
| `media` | Send a file from this plugin's files/package | No |
| `network` | Independent HTTP requests | No |
| `settings` | Shared Whitegram preferences | No |
| `clipboard` | System clipboard reads/writes | No |

The first seven IDs use recovered legacy permission names; `clipboard` is a port-specific permission. Declared package permissions are displayed, not automatically granted. Change permissions in the plugin detail screen, then run the script. Changing a permission stops the current session. `wg.permissions.has(id)` checks a grant without prompting. Unknown declared permission IDs reject import.

Decisions are stored through `WhitegramPreferences` under `pluginRuntime.permissions.<account-record-id>.<installation-uuid>` inside the existing `WhitegramSettingsState.v1` store. Plugin `preferences` APIs cannot read/write `pluginRuntime.*`; they cannot grant permissions to themselves or other plugins. File sending additionally requires `messages` and `storage`; opening a Telegram chat additionally requires `uiMutation`.

Telegram event registrations are checked in JavaScript **and** in the native subscription entry point. Wildcard patterns that match protected Telegram events (including `*`) require `messages`. Delivery rechecks the grant, including SDK-handler callbacks; native request completions and peer-watch callbacks also recheck permissions. The runtime observes changes to its saved grants and stops if they differ from its startup snapshot. Stop disables the subscription immediately, including while the JS queue is busy.

## Implemented JavaScript APIs

### Execution and storage

- `console.log/info/debug/warn/error`, `wg.log`, `wg.logLevel` — real manager log entries.
- `setTimeout`, `setInterval`, matching clear functions, the `wg.*` timer names, and cancellable `wg.sleep(ms)`. Timers accept functions; globals support additional arguments.
- `wg.BasePlugin`, `wg.registerPlugin(instance)`, `module.exports = instance`, or an exported constructor. Exported hook-only lifecycle objects also register. An object is registered once without rewriting its methods; frozen objects work. Hook registration validates the entire set and rolls back partial registration on error. Promise-returning `onLoad`, including plugins registered during another awaited `onLoad`, is awaited. Its rejection fails startup and cleans up the session.
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

`wg.getCurrentChat()` and the recovered `wg.client.currentChat()` synchronously return the latest visible standard cloud-peer chat for this account, or `null`. `invoke("client.getCurrentChat")` returns the same result through its Promise/callback contract. Snapshots contain `{id,peerId,threadId,title,viewId}`; peer/thread IDs are strings. ChatController `viewDidAppear`/`viewDidDisappear` and deinit maintain the snapshot. Closing an older controller cannot clear another controller's current chat. This describes visibility, including returning from a pushed screen; it does not resolve an arbitrary/background chat.

Native signatures were cross-checked against the full `whitegram-port-12.9.2` source: `EngineRawMessage`, `EngineRawMedia`, `EnginePeer.Id`, `EngineMessage.Id/Index`, `EngineHistoryViewInputAnchor`, the engine message methods, Postbox history views and media constructors. In particular, cached history uses `[EngineRawMessage]`, avoiding the unrelated exported FlatBuffers `Message<T>` name. Message resources are stored through MediaBox's asynchronous data queue.

### Events and watches

- `wg.on(event, callback)` returns a registration ID; `wg.off(event, idOrCallback?)` releases it. The recovered `wg.hook(event, callback)` returns the callback, which can be passed to `off`. Recovered `wg.events.on/once/off/emit/sticky/stream` support wildcard patterns. Legacy and SDK listeners share native subscription interest until the last registration is removed. Custom emitted names must start with `plugin.` and are local to this plugin.
- Native events: `app.foreground`, `app.background`, `app.screenshot`, `theme.changed`, and `settings.changed` (the last requires `settings`). Lifecycle aliases `onAppForeground`, `onAppBackground`, `onScreenshot`, `onThemeChange` are connected.
- `await wg.chat.watchMessages(peerId, callback, limit=50)` subscribes to that peer's Postbox cloud-history view and returns `{id,close()}`. Callbacks receive `{peerId,messages,scope:"local",initial}` snapshots. The initial snapshot can arrive while subscription setup is completing. This is not a global incoming-message hook or a server-history backfill.
- Streams implement `Symbol.asyncIterator`, close pending `next()` on stop, and retain at most 256 undrained events (oldest dropped). Separate registrations of the same function have independent IDs.
- Removing another event pattern inside a callback does not invalidate the current delivery snapshot or abort later delivery.

With the hook patch module installed, these **original names** are supported:

| Event / method | Source and meaning |
| --- | --- |
| `onMessageReceive` | New, previously uncached incoming cloud messages in `AccountStateManagementUtils.replayFinalState`, `.UpperHistoryBlock` only. History backfill and replayed IDs do not masquerade as new messages. |
| `onOutgoingMessage` | Actual local IDs from the transaction-level `enqueueMessages`, including standard forwards/resends. Payload has `queued:true`; server acceptance has not occurred yet. |
| `onMessageSend` | Local→cloud ID mapping in `applyUpdateMessage` / `applyUpdateGroupMessages`. Payload has `sent:true` and `localId:{peerId,id,namespace}`. This is server acknowledgement, not the recipient reading the message. |
| `onUpdate`, `wg.onUpdate(callback)`, `tg.update` | `onUpdate` is normalized to the `tg.update` name shown in the recovered SDK. The port emits bounded observations with `type`: `messageReceived`, `messageQueued`, `messageSent`, `messageEdited`, `messageDeleted`, `chatOpened`, or `chatClosed`. |
| `onUpdates` | `{updates:[observation],scope:"postbox",interceptable:false}`. Each native observation is a one-item batch; no raw MTProto update batch is promised. |
| `onChatOpen` / `onChatClose` | The same visibility boundaries and per-view identity used by `getCurrentChat()`. |

Edits are captured from state replay and all four successful edit-response branches, with actual post-update flags/media. Unchanged content/entities/media/edit dates are skipped, including a matching response echo. Deletions observe loaded preimages for explicit cloud IDs, resolved global IDs, and local interactive deletion; an already-removed server echo has no second preimage. Their `onUpdate`/`tg.update` observations use `messageEdited` / `messageDeleted`. There are no fabricated `onMessageEdit`/`onMessageDelete` legacy methods.

Message observations expose `{peerId,id,messageId,namespace,text,textTruncated,date,outgoing,pending,authorId,threadId,editDate,hasMedia}`, plus `scope:"postbox"`, `source`, and `interceptable:false`. Edits add `previous`, containing the prior message snapshot. Text is bounded at 16 KiB UTF-8. These are documented **reconstructed observation envelopes**, not a claim to have recovered the complete original payload ABI or TL objects.

All these callbacks are asynchronous observations. `wg.intercept`, request hooks (`preRequest`/`postRequest`, `onRequest`/`onResponse`), `onSendMessage`, and overrides remain unsupported. Returning cancel/modify/replace from an observational handler logs a warning and cannot alter an already accepted native operation. Capability info advertises `globalTelegramEvents:true`, `eventSemantics:"observational-postbox"`, and the exact event names; `globalTelegramHooks`/`interceptors` remain false.

The Foundation-only `WhitegramPluginEventHub` scopes subscriptions by **Postbox object identity**, not the global current account. Payloads become immutable JSON before crossing queues. Each batch is snapshotted before a read-only Postbox transaction barrier and enters the owning JS queue only after that barrier completes. Events from later transactions await a later barrier. There is at most one in-flight batch and one pending FIFO per plugin; each holds at most 256 events / 1 MiB, with a 64 KiB limit per event. Overflow drops oldest pending observations and reports a bounded log diagnostic. Subscription generations suppress queued events after off→on replacement; stop/restart never transfers a former session's queue.

### Native UI

`wg.ui.window/panel/sheet/screen`, `wg.screens.push/present`, surface `update/setState/setTitle/set/show/hide/close/info`, `ui.surfaces/closeAll`, theme, keyboard height, haptics, toast/action-toast, confirm, menu and prompt are connected. Surface creation is synchronous: a returned ID belongs to an allocated and validated native controller. Unknown nodes and unavailable presentation contexts throw errors.

Supported elements: VStack, HStack, Card, Glass/Blur (UIKit materials), Section, List/Scroll, Text, Button/Row, Toggle, Slider, Stepper, TextField, TextArea, Segmented, Progress, Spinner, Spacer, Divider, Icon and Image. TextField/TextArea `id` or `bind` preserves focus on rerender; `bind` and `rerender:false` use the recovered state contract. Segmented options are strings and its value is an index. Images come from the plugin package or base64 image data URLs; there is no implicit remote image fetch. Icons use SF Symbol names.

Windows/panels/sheets use Telegram's navigation-modal presentation; screens are created hidden until pushed/shown. These are not draggable floating windows. There is one outer scrolling container; nested List/Scroll nodes form vertical content. Live option changes currently apply the title. Styling supports spacing, padding, text size/weight/color/alignment, enabled/hidden and the documented control values; arbitrary original window/layout/material options are not fully reproduced. Web/HTML, ZStack layering, overlays, tabs, chat/header buttons and native UI injection slots reject explicitly.

UI callback tokens are dispatched on the JS queue; UIKit never retains JSValue callbacks. Rerender discards stale callbacks. If a replacement tree fails native validation, its surface closes because the recovered core has already invalidated the previous callback map. Async callbacks supplied through creation, `surface.update`, `surface.set` and prompts log rejections. Toast expiration frees its action without firing it. Confirm success callbacks receive one boolean; menu success callbacks receive `(index, title)`, preserving the recovered contracts. Other application-created promises should be awaited or given `.catch(console.error)`; JavaScriptCore does not supply the browser's global unhandled-rejection event.

### Dynamically registered plugin settings

`registerSettingsPage(config)`, `addSettingsRow(config)`, and `openSettingsPage(id)` are connected, including the recovered `wg.settings.registerPage/addRow/openPage` wrappers. Native metadata appears under **Plugin Controls in that running plugin's detail screen**. Registration allocates no visible screen. Selecting a page builds a real SDK-driven native screen; selecting a row dispatches its `hookName` on the plugin's JS queue. These rows are placed in the plugin manager, not the application's global settings list.

```javascript
wg.settings.registerPage({
  id: "main", title: "My plugin", controls: [
    { id: "enabled", type: "toggle", title: "Enabled", value: true,
      hookName: "plugin.enabledChanged" },
    { id: "level", type: "slider", title: "Level", min: 0, max: 100, value: 50 },
    { id: "name", type: "input", title: "Name", value: "" },
    { id: "mode", type: "select", title: "Mode", value: "quiet", options: [
      { title: "Quiet", value: "quiet" }, { label: "Verbose", value: "verbose" }
    ] },
    { id: "info", type: "info", title: "Changes are saved for this installation." }
  ]
});
wg.settings.addRow({ id: "open", title: "Open preferences",
  hookName: "__wg_open_settings_page:main" });
wg.on("plugin.enabledChanged", function (change) { console.log(change.value); });
```

Page schema: `{id,title,controls}`. Control fields follow the recovered native `WGPluginSettingControl`: `{id,type,title,subtitle,value,min,max,options,hookName}`. Supported types are `switch`/`toggle`, `slider` (default range 0–100), `text`/`input`, `select`/`menu`, `label`/`info`, and action `button`. Selection options are string-valued dictionaries: title falls back to label, then value; value falls back to the displayed title. Selections use a real native action sheet. Labels/info are noninteractive. Unknown types, invalid ranges, duplicate control IDs and invalid values reject registration.

Values persist through the existing `settings.getValue/setValue` / `getSettingsValue/setSettingsValue` storage keys and require `storage`. User changes emit the configured hook with `{pageId,controlId,value}` after a successful write. Programmatic `setValue` updates an open page without firing a second user-change event. Rows use `{id,title,subtitle,hookName}` and emit `{id,pluginId}`; the recovered `__wg_open_settings_page:` prefix opens a registered page directly. `settings.addSwitch` retains its recovered helper behavior: it registers an **action row** and returns `settings:<key>`; use a page's `switch`/`toggle` control for an actual persisted switch.

Up to eight pages, 32 rows and 64 controls/page are allowed. Re-registering an ID replaces its metadata and live tree. Native activation tokens and SDK callback replacement reject old taps; a selection result from a replaced/closed page is discarded. Stop, failure, account removal, deletion and permission changes remove the native entries and screens. `openSettingsPage` returns the port's managed surface handle; repeated opens reuse an extant page. Arbitrary application settings/menu/chat injection and `ui.provide` slots remain unsupported.

## Original evidence and provenance

Evidence root: `C:\coding\telegram\whitegram\whitegram-rebuild`.

- `recovered-3.1.1/embedded-source/plugin-lifecycle-477330d74d61.js`: original lifecycle method map, `hook`'s callback return, `onUpdate`/request/send aliases, and settings wrapper signatures.
- `recovered-3.1.1/embedded-source/sdk-extensions-8c7bf3946b42.js`: separate events/subscribe/unsubscribe, wildcard/once/stream, `tg.update` example, interceptor and provider contracts. The latter are not passed off as observational callbacks.
- `recovered-3.1.1/embedded-source/sdk-core-96d89247b19c.js`: reused native surface normalization, state and callback lifetime.
- `recovered-3.1.1/native/TelegramUIFramework-0/types.json`: `WGPluginSettingsRow`, `WGPluginSettingControl` and `WGPluginSettingsPage` fields, including string-dictionary options. `method-audit-3.1.1/image-055-methods.json` identifies the page's cell, selection, text, switch and slider methods.
- Original image 55 cell implementation **`0xd3c924`**, reached from the recovered `tableView:cellForRowAtIndexPath:` thunk at **`0xd3d748`**, confirms type comparisons: switch/toggle at `0xd3cd60`/`0xd3cd80`, slider at `0xd3cec0`, select/menu at `0xd3d02c`/`0xd3d05c`, text/input at `0xd3d0b8`/`0xd3d0ec`, label/info at `0xd3d23c`/`0xd3d254`. Its slider default `0x42c80000` is 100. The selection implementation **`0xd3da58`** confirms option `title`→`label`→`value` lookup and value→display-title fallback. These were inspected using the existing read-only `wgtool audit-function` against the SHA-verified original IPA.
- `audit-full-3.1.1/audit.sqlite3`, image 55, contains `onMessageReceive` at `0x4bd90e0`, `onOutgoingMessage` at `0x4bd9100`, and `__wg_open_settings_page:` at `0x4bfb4a0`. `recovered-3.1.1/native/TelegramCoreFramework-0/symbols.json` preserves the original Core `WGPluginHost.emit` / listener registration boundary.

`hooks.test.cjs` checks SHA-256 of all five recovered execution resources against `recovered-3.1.1/manifest.json`: core `96d89247b19c…`, lifecycle `477330d74d61…`, extensions `8c7bf3946b42…`, permission bridge `d5f595fdf134…`, unload host `9839d4369f98…`. Recovered bytes remain intact; adapter behavior is implemented in `whitegram-native-bootstrap.js`. The exact input IPA hash is `bd6d3a13046d5857c1389e2d794c4c2ca44cee89bb22880004bd77f84fe29837`.

## Lifecycle, limits and unsupported areas

Each plugin has a serial JS queue and a separate JSContext/VM. UIKit runs on main; main never synchronously waits for a JS queue. Synchronous native UI calls hop to main only from JS. Async calls use JSON and bounded request tokens; no AccountContext, UIKit object, Telegram session or retained JSValue callback crosses the bridge.

Stop immediately revokes the native session, disposes the event subscription/queued observations, cancels timers, HTTP and Signal subscriptions, and closes native UI/settings registrations. Repeated Stop calls share one queued teardown and complete after it finishes. On the owning JS queue it rejects pending requests/sleeps, ends streams, marks surface handles closed, calls recovered `onUnload`, clears callbacks and releases the context. `onUnload` supports synchronous logging and own `wg.storage` reads/writes; starting new async work during unload fails. Async `onUnload` is not awaited. Startup's async `onLoad` has a 30-second cooperative deadline; ordinary native requests have a 65-second outer deadline and dialogs 120 seconds. Each request also has a cancellation lifetime: expired work is rejected before starting a queued main-thread operation or Telegram mutation, and dialog cancellation dismisses only the dialog belonging to that request.

**A non-yielding JavaScript loop cannot be forcibly interrupted with the public JavaScriptCore APIs used here.** Stop still disables native operations and closes UI, but its queued JS teardown cannot finish until that script yields. Such a session stays stopping; an app restart is needed for a permanently looping script. Node's test VM timeout is not a production watchdog. This is an imported-code capability boundary, not a hard CPU/heap sandbox. iOS suspension is respected; timers/jobs do not promise background execution.

Bounds: eight running plugins/account, eight surfaces/plugin, four visible toasts/plugin, eight watched peers/plugin, 256 timers (interval minimum 16 ms), 128 pending native requests, 16 simultaneous HTTP tasks, 256 event handlers per event API, 64 streams and 64 sticky events. Transfers/files/HTTP bodies and responses are capped at 2 MiB; byte-token storage at 4 MiB/32 tokens; a decoded package at 8 MiB/256 files and its import document at 12 MiB; writable files at 16 MiB/256 files; JSON state at 2 MiB. Paths have at most 32 components and 1024 UTF-8 bytes. Logs retain 200 entries/plugin, up to 8 KiB/entry and 100 entries/second, in memory for the manager session.

Explicitly unsupported: Telegram request/update overrides, synchronous/deferred interception, raw MTProto or full protocol update events; arbitrary postbox transactions; inter-plugin services; durable/background jobs; global settings/menu/chat/header injection, tabs and provider slots; TCP/UDP/DNS/WebSocket tools; download/upload convenience APIs; external filesystem access; browser DOM/Worker APIs; Python/Lua/Ruby/Go runtimes; TypeScript compilation; and `wg.wasm` execution. Event coverage excludes secret chats, community-specific/ephemeral/scheduled/quick-reply message paths, history-clearing ranges, uncached deletion IDs and outgoing messages sent solely by another client. It is a live bounded observer, not a durable audit/backfill feed. Unsupported calls fail explicitly and are absent from capability discovery.

The bootstrap repairs known recovered-JS compatibility issues without editing recovered files: hard-coded HTTP 200, discarded reply IDs, immediate-success `invoke` mutations, nonrejecting dialog adapters, missing stream iterators, cached failed modules, function-form surfaces, reused-handler IDs, async callback logging and toast callback cleanup. The resumed review additionally fixed frozen/nested lifecycle registration, `msgId`/menu-title contracts, failed byte-pack/revival cleanup, event unsubscription during delivery, empty POSTs and replacement-surface callback ownership.

## Verification

Run from the build repository root:

```powershell
node --test "whitegram/tests/plugins/*.test.cjs"
& "C:\Users\Pisun4ik\AppData\Local\Temp\opencode\whitegram-check-env\Scripts\python.exe" -B "whitegram/tests/plugins/check_swift_syntax.py"
& "C:\Users\Pisun4ik\AppData\Local\Temp\opencode\whitegram-check-env\Scripts\python.exe" -B "whitegram/tests/plugins/check_hook_patches.py" "C:\Users\Pisun4ik\AppData\Local\Temp\opencode\whitegram-validate-12.9.2"
```

The Node suite loads the **actual recovered core/extensions/lifecycle/permission bridge** and new bootstrap. Its JSON host fixture consumes native Swift resource/registry/event declarations. **51 tests passed** after the event/settings slice: existing contracts plus subscription union/removal, hook-only exports, legacy aliases/streams, failed-registration rollback, revocation, truthful HookResults, dynamic pages/rows, native-evidenced control aliases, stale UI tokens, late selection results, provenance hashes, and both shipped examples. Native Telegram/UIKit/URLSession/Postbox behavior is represented by explicit fixtures; Node results are not evidence of device execution or native path/symlink enforcement.

The supplied XCTest files exercise actual Foundation code:

- `WhitegramPluginStorageTests.swift`: **9 cases** covering containment/symlinks, replaced roots, internal module parents, persistent JSON/files, invalid state/quotas, non-evaluating imports, canonical/file-directory collisions, bounded reads, and strict JSON boolean/number handling.
- `WhitegramPluginHTTPTests.swift`: request construction, JSON/base64 bodies and timeouts, invalid URLs/options/headers/quotas, and cross-origin credential stripping.
- `WhitegramPreferencesTests.swift`: shared preference visibility, aliases, migration and type handling.
- `WhitegramPluginEventHubTests.swift`: **7 new cases** against the production Foundation hub for commit barriers, JS queue confinement, later-transaction ordering, account isolation, restart/off→on generations, bounded FIFO/byte budget/drop diagnostics and reentrant disposal.

Run the Foundation tests on an Apple host with `python3 -B whitegram/tests/plugins/run_native.py`, or in a SettingsUI/TelegramCore-linked XCTest host. `run_native.py` copies the actual event hub into its lightweight TelegramCore test module. **The native XCTest cases have not been executed in this Windows environment.**

`check_swift_syntax.py` parsed **12 plugin implementation/XCTest files** successfully with tree-sitter 0.25.2 / tree-sitter-swift 0.7.3. It refuses other version pairs before loading the parser (0.26 is known to crash here). `check_hook_patches.py` verified both history/hook application orders, repeat idempotence, 16 exact callsites, no additional syntax errors in all six patched upstream files, unchanged read-only inputs, and rejection of missing/ambiguous anchors. Syntax parsing is not type checking, linking, a Bazel build or simulator/device validation. The referenced Telegram signatures were inspected at `6ad963e5b6`. There is no local Xcode/Swift compiler; an Apple build and device smoke test remain necessary.

For a hands-on smoke test, import `whitegram/tests/plugins/example-notes.js`. It creates a real SDK-driven native Notes sheet and persists edits using `storage`; sending to Saved Messages requires enabling `account` and `messages` and tapping its Send button.

`example-event-monitor.js` uses the original BasePlugin/onUpdate/settings APIs. Enable `messages`, Run, and open **Plugin Controls → Event monitor → Open live log**. Receive/send/edit/delete messages and navigate chats; the screen records the observed type and IDs. The persisted toggle/filter controls change which events the example displays. It sends no messages. Confirm that Stop/revocation removes its entries/screens and that two signed-in accounts do not share observations.

On device, also confirm Stop during a pending HTTP request/dialog/watch, rapid Stop/Run/Delete actions, rejected permission calls, persistence across relaunch, and the absence of callbacks after teardown. These native lifecycle/presentation scenarios were reviewed in source, not executed by the Node fixture.
