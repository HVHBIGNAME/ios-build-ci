(function (global) {
  "use strict";
  // The two host functions exchange JSON only. Native code never retains a JS
  // callback; tokens are settled on the owning JavaScriptCore serial queue.
  var hostSync = global.__wgHostSync;
  var hostAsync = global.__wgHostAsync;
  if (typeof hostSync !== "function" || typeof hostAsync !== "function") {
    throw new Error("Whitegram native host is missing");
  }
  delete global.__wgHostSync;
  delete global.__wgHostAsync;
  var stopped = false, stopping = false, sequence = 0;
  var pending = Object.create(null), timers = Object.create(null);
  var listeners = Object.create(null), sticky = Object.create(null);
  var bytePool = Object.create(null), byteCount = 0;
  var sleepers = Object.create(null), toastActions = Object.create(null), streams = [];
  var uiDispatch = null, eventRegistrations = [];
  var loadPromises = [], installed = false, finishedEntry = false, runtimeStarted = false;
  var stringify = JSON.stringify.bind(JSON), parse = JSON.parse.bind(JSON);

  function fault(code, message) {
    var error = new Error(message);
    error.code = code;
    return error;
  }
  function errorValue(error) {
    return { code: error && error.code || "PLUGIN_ERROR", message: String(error && error.message || error) };
  }
  function assertActive() {
    if (stopped || stopping) throw fault("PLUGIN_STOPPED", "This plugin has stopped");
  }
  function unsupported(path) {
    var fn = function () { throw fault("UNSUPPORTED_API", "wg." + path + " is not implemented in this build"); };
    fn.__wgUnsupported = true;
    return new Proxy(fn, { get: function (target, key) {
      if (key in target || typeof key !== "string") return target[key];
      if (key === "then" || key === "toJSON") return undefined;
      return unsupported(path + "." + key);
    } });
  }
  function unsupportedObject(path, object) {
    return new Proxy(object || {}, {
      get: function (target, key) {
        if (key in target || typeof key !== "string") return target[key];
        if (key === "then" || key === "toJSON") return undefined;
        return unsupported(path ? path + "." + key : key);
      }
    });
  }
  function envelope(result) {
    if (!result || typeof result.ok !== "boolean") throw fault("BRIDGE_ERROR", "Invalid native response");
    if (!result.ok) throw fault(result.error && result.error.code || "NATIVE_ERROR", result.error && result.error.message || "Native call failed");
    return result.value;
  }
  function sync(path, args, duringStop) {
    if (!duringStop && !(stopping && !stopped && path.indexOf("storage.") === 0)) assertActive();
    return envelope(parse(hostSync(path, stringify(args || []))));
  }
  function safeCallback(callback, args) {
    if (typeof callback !== "function") return;
    try { observePromise(callback.apply(null, args)); }
    catch (error) { log("error", error && error.stack || error); }
  }
  function observePromise(value) {
    if (value && typeof value.then === "function") Promise.resolve(value).catch(function (error) { log("error", error && error.stack || error); });
    return value;
  }
  function observeCallback(callback) {
    return function () { return observePromise(callback.apply(this, arguments)); };
  }
  function observeTree(node) {
    if (Array.isArray(node)) return node.map(observeTree);
    if (!node || typeof node !== "object") return node;
    var copy = {};
    Object.keys(node).forEach(function (key) {
      if (key === "children") copy[key] = observeTree(node[key]);
      else if (key === "props") {
        copy.props = {};
        Object.keys(node.props || {}).forEach(function (prop) { copy.props[prop] = typeof node.props[prop] === "function" ? observeCallback(node.props[prop]) : node.props[prop]; });
      } else copy[key] = typeof node[key] === "function" ? observeCallback(node[key]) : node[key];
    });
    return copy;
  }
  function log(level, message) {
    if (stopped) return;
    try { sync("log", [String(level), String(message)], true); }
    catch (_) { /* Logging must not recursively report a stopped host. */ }
  }
  function async(path, args) {
    return new Promise(function (resolve, reject) {
      try {
        assertActive();
        if (Object.keys(pending).length >= 128) throw fault("QUOTA_EXCEEDED", "Too many pending plugin requests");
        var payload = stringify(args || []);
        var token = "r" + (++sequence);
        pending[token] = { resolve: resolve, reject: reject };
        try { hostAsync(path, payload, token); }
        catch (error) { delete pending[token]; throw error; }
      } catch (error) { reject(error); }
    });
  }
  global.__wgNativeComplete = function (token, response) {
    var callback = pending[token];
    if (!callback || stopped || stopping) return;
    delete pending[token];
    try { callback.resolve(envelope(response)); }
    catch (error) { callback.reject(error); }
  };
  function resultCallback(promise, callback) {
    if (typeof callback === "function") {
      promise.then(function (value) { safeCallback(callback, [value, null]); }, function (error) { safeCallback(callback, [null, errorValue(error)]); });
    }
    return promise;
  }
  function legacy(path) {
    return function () {
      var args = Array.prototype.slice.call(arguments);
      var callback = typeof args[args.length - 1] === "function" ? args.pop() : null;
      return resultCallback(async(path, args), callback);
    };
  }
  function timer(callback, milliseconds, repeats) {
    assertActive();
    if (typeof callback !== "function") throw fault("INVALID_ARGUMENT", "Timer callback must be a function");
    if (Object.keys(timers).length >= 256) throw fault("QUOTA_EXCEEDED", "Too many plugin timers");
    var delay = Number(milliseconds) || 0;
    if (!isFinite(delay)) throw fault("INVALID_ARGUMENT", "Timer delay must be finite");
    delay = Math.min(86400000, Math.max(repeats ? 16 : 0, delay));
    var id = ++sequence;
    timers[id] = { callback: callback, repeats: repeats };
    try { sync("timer.create", [id, delay, repeats]); }
    catch (error) { delete timers[id]; throw error; }
    return id;
  }
  function clearTimer(id) {
    id = Number(id);
    if (!timers[id]) return;
    delete timers[id];
    if (!stopped && !stopping) sync("timer.clear", [id]);
  }
  global.__wgTimerFire = function (id) {
    var entry = timers[id];
    if (!entry || stopped || stopping) return;
    if (!entry.repeats) delete timers[id];
    safeCallback(entry.callback, []);
  };

  var info = sync("runtime.info");
  var manifest = info.manifest;
  var supported = Object.create(null), permissionTable = Object.create(null);
  manifest.forEach(function (entry) {
    supported[entry.path] = entry;
    if (entry.permission) permissionTable[entry.path] = entry.permission;
  });
  function gate(permission, path) {
    var unloadStorage = stopping && !stopped && permission === "storage" && String(path).indexOf("storage.") === 0;
    return sync("permissions.check", [String(permission), String(path)], unloadStorage);
  }
  global.__wgPermissionGate = gate;
  global.__wgPermissionTable = permissionTable;
  function assertPermission(permission, path) {
    if (!gate(permission, path)) throw fault("PERMISSION_DENIED", "wg." + path + " requires " + permission);
  }
  function matches(pattern, name) {
    var escaped = pattern.replace(/[.+?^${}()|[\]\\]/g, "\\$&").replace(/\*/g, ".*");
    return new RegExp("^" + escaped + "$").test(name);
  }
  var legacyEvents = {
    onAppForeground: "app.foreground", onAppBackground: "app.background",
    onThemeChange: "theme.changed", onScreenshot: "app.screenshot"
  };
  function validateEvent(pattern) {
    assertActive();
    if (!pattern || pattern.length > 256) throw fault("INVALID_ARGUMENT", "Invalid event name");
    if (pattern === "prototype" || Object.prototype.hasOwnProperty.call(Object.prototype, pattern)) throw fault("INVALID_ARGUMENT", "Reserved event name");
    if (/^(onMessage|onOutgoing|onChat|onUpdate|onSendMessage|preRequest|postRequest|override:|tg\.)/.test(pattern)) {
      throw fault("UNSUPPORTED_API", "Global Telegram hooks are unavailable; use wg.chat.watchMessages for a specific peer");
    }
    return legacyEvents[pattern] || pattern;
  }
  function on(event, callback) {
    var name = validateEvent(String(event));
    if (typeof callback !== "function") throw fault("INVALID_ARGUMENT", "Event handler must be a function");
    var count = Object.keys(listeners).reduce(function (n, key) { return n + listeners[key].length; }, 0);
    if (count >= 256) throw fault("QUOTA_EXCEEDED", "Too many event handlers");
    var id = "e" + (++sequence);
    (listeners[name] || (listeners[name] = [])).push({ id: id, callback: callback });
    return id;
  }
  function off(event, id) {
    var name = legacyEvents[event] || String(event);
    if (!listeners[name]) return;
    if (id == null) delete listeners[name];
    else listeners[name] = listeners[name].filter(function (entry) { return entry.id !== id && entry.callback !== id; });
    if (listeners[name] && !listeners[name].length) delete listeners[name];
  }
  function emit(name, payload) {
    if (stopped || stopping) return;
    var callbacks = [];
    Object.keys(listeners).forEach(function (pattern) {
      if (matches(pattern, name)) callbacks = callbacks.concat(listeners[pattern]);
    });
    callbacks.forEach(function (entry) { if (!stopped && !stopping) safeCallback(entry.callback, [payload, name]); });
    if (!stopped && !stopping && typeof global.__wgSDKEvent === "function") byteScope(function () { global.__wgSDKEvent(name, transfer(payload, true)); });
  }
  global.__wgNativeEvent = emit;

  var wg = {
    pluginId: info.id, pluginName: info.name, pluginVersion: info.version,
    log: function (message) { log("info", message); }, logLevel: log,
    setTimeout: function (callback, ms) { return timer(callback, ms, false); },
    setInterval: function (callback, ms) { return timer(callback, ms, true); },
    clearTimeout: clearTimer, clearInterval: clearTimer,
    on: on, off: off,
    storage: {}, ui: {}, tg: {}, preferences: {}, chat: {}
  };
  ["get", "set", "remove", "keys", "clear"].forEach(function (method) {
    wg.storage[method] = function () { return sync("storage." + method, Array.prototype.slice.call(arguments)); };
  });
  ["getMe", "getPeer", "getChatList", "getMessages", "sendTextMessage", "sendFileMessage", "sendDiceMessage", "sendLocationMessage", "sendContactMessage",
    "editMessage", "deleteMessage", "forwardMessage", "pinMessage", "reactToMessage", "markChatAsRead", "openChat"].forEach(function (name) {
    wg[name] = legacy("tg." + name);
    permissionTable[name] = name === "getMe" ? "account" : name === "sendFileMessage" ? "media" : "messages";
  });
  wg.getCurrentChat = unsupported("getCurrentChat");
  wg.ui.confirm = function (title, message, callback) {
    return async("ui.confirm", [title, message]).then(function (value) { safeCallback(callback, [value]); return value; });
  };
  wg.ui.actionSheet = function (title, message, items, callback) {
    return async("ui.actionSheet", [title, message, items]).then(function (index) {
      safeCallback(callback, [index, index >= 0 ? items[index] : null]);
      return index;
    });
  };
  var native = {};
  ["createSurface", "updateSurface", "setSurfaceOptions", "setSurfaceVisible", "closeSurface", "surfaceInfo", "pushScreen", "theme", "keyboardHeight", "haptic", "toast"].forEach(function (method) {
    native[method] = function () { return sync("ui." + method, Array.prototype.slice.call(arguments)); };
  });
  native.resolveModule = function (directory, name) { return sync("package.resolveModule", [directory, name]); };
  native.listPackageFiles = function () { return sync("package.list"); };
  native.readPackageFile = function (path, base64) { return sync("package.read", [path, !!base64]); };
  wg.__native = unsupportedObject("__native", native);
  wg.__net = unsupportedObject("net", {
    httpTiming: function (url, callback) { return resultCallback(async("http.request", [{ url: url, method: "HEAD" }]), callback); }
  });
  wg.__lang = {
    isInstalled: function () { return false; }, installed: function () { return []; },
    request: function (language, operation, payload, callback) { callback({ ok: false, error: "UNSUPPORTED_LANGUAGE: " + language + " is not bundled" }); },
    transpileTypeScript: function () { return { ok: false, error: "UNSUPPORTED_LANGUAGE: TypeScript compiler is not bundled" }; },
    promptInstall: function () { throw fault("UNSUPPORTED_LANGUAGE", "External language runtimes cannot be installed by this build"); }
  };

  var alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
  function encodeBytes(bytes) {
    var output = "";
    for (var i = 0; i < bytes.length; i += 3) {
      var a = bytes[i], b = bytes[i + 1], c = bytes[i + 2];
      output += alphabet[a >> 2] + alphabet[((a & 3) << 4) | ((b || 0) >> 4)] +
        (i + 1 < bytes.length ? alphabet[((b & 15) << 2) | ((c || 0) >> 6)] : "=") +
        (i + 2 < bytes.length ? alphabet[c & 63] : "=");
    }
    return output;
  }
  function decodeBytes(text) {
    if (!/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(text)) throw fault("INVALID_ARGUMENT", "Invalid base64");
    var length = text.length * 3 / 4 - (text.endsWith("==") ? 2 : text.endsWith("=") ? 1 : 0);
    var bytes = new Uint8Array(length), offset = 0;
    for (var i = 0; i < text.length; i += 4) {
      var n = (alphabet.indexOf(text[i]) << 18) | (alphabet.indexOf(text[i + 1]) << 12) |
        (Math.max(0, alphabet.indexOf(text[i + 2])) << 6) | Math.max(0, alphabet.indexOf(text[i + 3]));
      if (offset < length) bytes[offset++] = (n >> 16) & 255;
      if (offset < length) bytes[offset++] = (n >> 8) & 255;
      if (offset < length) bytes[offset++] = n & 255;
    }
    return bytes;
  }
  function putBytes(bytes) {
    assertActive();
    if (!(bytes instanceof Uint8Array)) throw fault("INVALID_ARGUMENT", "putBytes expects Uint8Array");
    if (byteCount + bytes.byteLength > 4 * 1024 * 1024 || Object.keys(bytePool).length >= 32) throw fault("QUOTA_EXCEEDED", "Byte transfer pool is full");
    var id = ++sequence;
    bytePool[id] = new Uint8Array(bytes);
    byteCount += bytePool[id].byteLength;
    return id;
  }
  function takeBytes(id) {
    var bytes = bytePool[id];
    if (!bytes) throw fault("INVALID_ARGUMENT", "Unknown or already consumed byte token");
    delete bytePool[id];
    byteCount -= bytes.byteLength;
    return bytes;
  }
  function byteScope(callback) {
    var start = sequence;
    try { return callback(); }
    finally {
      Object.keys(bytePool).forEach(function (id) {
        if (Number(id) > start) { byteCount -= bytePool[id].byteLength; delete bytePool[id]; }
      });
    }
  }
  function scopedBytes(callback) {
    return function () {
      var owner = this, args = arguments;
      return byteScope(function () { return callback.apply(owner, args); });
    };
  }
  function transfer(value, inbound) {
    if (!value || typeof value !== "object") return value;
    if (inbound && typeof value.__wgBase64 === "string") return { __wgBytes: putBytes(decodeBytes(value.__wgBase64)) };
    if (!inbound && typeof value.__wgBytes === "number") return { __wgBase64: encodeBytes(takeBytes(value.__wgBytes)) };
    if (Array.isArray(value)) return value.map(function (item) { return transfer(item, inbound); });
    var out = Object.create(null);
    Object.keys(value).forEach(function (key) { out[key] = transfer(value[key], inbound); });
    return out;
  }
  var subscriptions = Object.create(null);
  var sdk = {
    manifest: function () { return manifest.filter(function (entry) { return entry.exposed; }); },
    call: function (path, args, resolve, reject) {
      try {
        if (!supported[path] || !supported[path].exposed) throw fault("UNSUPPORTED_API", "wg." + path + " is not an exposed registry method");
        var values = transfer(args, false);
        var promise = supported[path].sync ? Promise.resolve(sync(path, values)) : async(path, values);
        promise.then(function (value) {
          // The extension's resolve callback revives bytes and can throw. That
          // failure must reach reject rather than strand its outer Promise.
          try { byteScope(function () { observePromise(resolve(transfer(value, true))); }); }
          catch (error) { safeCallback(reject, [errorValue(error)]); }
        }, function (error) { safeCallback(reject, [errorValue(error)]); });
      } catch (error) { safeCallback(reject, [errorValue(error)]); }
    },
    callSync: function (path, args) {
      try {
        if (!supported[path] || !supported[path].exposed || !supported[path].sync) throw fault("UNSUPPORTED_API", "wg." + path + " has no exposed synchronous implementation");
        return { ok: true, value: transfer(sync(path, transfer(args, false)), true) };
      } catch (error) { return { ok: false, error: errorValue(error) }; }
    },
    putBytes: putBytes, takeBytes: takeBytes,
    log: function (level, area, message) { log(level, area + ": " + message); },
    subscribe: function (pattern) {
      validateEvent(pattern);
      if (!subscriptions[pattern] && Object.keys(subscriptions).length >= 256) throw fault("QUOTA_EXCEEDED", "Too many event subscriptions");
      subscriptions[pattern] = true;
    },
    unsubscribe: function (pattern) { delete subscriptions[pattern]; },
    emit: function (name, payload, save) {
      assertActive();
      if (!name.startsWith("plugin.")) throw fault("INVALID_ARGUMENT", "Custom events must start with plugin.");
      payload = transfer(payload, false);
      if (stringify(payload).length > 65536) throw fault("QUOTA_EXCEEDED", "Event payload is too large");
      if (save) {
        if (!(name in sticky) && Object.keys(sticky).length >= 64) throw fault("QUOTA_EXCEEDED", "Too many sticky events");
        sticky[name] = payload;
      }
      // Defer delivery to preserve the SDK once() registration contract.
      wg.setTimeout(function () { emit(name, payload); }, 0);
    },
    sticky: function (pattern) {
      return Object.keys(sticky).filter(function (name) { return matches(pattern, name); }).map(function (name) { return { name: name, payload: transfer(parse(stringify(sticky[name])), true) }; });
    }
  };
  wg.__sdk = unsupportedObject("__sdk", sdk);
  global.wg = wg;

  function request(options, callback) {
    if (typeof options === "string") options = { url: options };
    var promise = async("http.request", [options || {}]);
    if (typeof callback === "function") promise.then(function (response) { safeCallback(callback, [null, response]); }, function (error) { safeCallback(callback, [errorValue(error), null]); });
    return promise;
  }
  function fetchBody(url, body, headers, callback, json, method) {
    var options = { url: String(url), method: method || "GET", headers: headers || {} };
    if (body !== undefined) options.body = body;
    var promise = request(options).then(function (response) {
      if (!response.ok) throw fault("HTTP_STATUS", "HTTP " + response.status + " for " + response.url);
      if (typeof response.body !== "string") throw fault("INVALID_ENCODING", "Response is not UTF-8; use wg.request and response.base64");
      return json ? parse(response.body) : response.body;
    });
    if (typeof callback === "function") promise.then(function (value) { safeCallback(callback, [null, value]); }, function (error) { safeCallback(callback, [errorValue(error), null]); });
    return promise;
  }
  wg.fetch = function (url, callback) { return fetchBody(url, undefined, null, callback, false); };
  wg.fetchJSON = function (url, callback) { return fetchBody(url, undefined, null, callback, true); };
  wg.fetchPost = function (url, body, headers, callback) {
    if (typeof headers === "function") { callback = headers; headers = {}; }
    return fetchBody(url, body, headers, callback, false, "POST");
  };
  wg.fetchPostJSON = function (url, body, headers, callback) {
    if (typeof headers === "function") { callback = headers; headers = {}; }
    return fetchBody(url, body, headers, callback, true, "POST");
  };
  wg.request = request;
  function legacyHTTP(options, callback) {
    var promise = request(options).then(function (response) { response.error = null; return response; });
    if (typeof callback === "function") promise.then(function (response) { safeCallback(callback, [response]); }, function (error) {
      safeCallback(callback, [{ ok: false, error: errorValue(error), status: 0, body: null, url: options.url }]);
    });
    return promise;
  }
  ["fetch", "fetchJSON", "fetchPost", "fetchPostJSON", "request", "httpGet", "httpPost"].forEach(function (path) { permissionTable[path] = "network"; });

  // Called after the recovered core, lifecycle and extensions, before the
  // recovered permission wrapper and before any user entry script.
  global.__wgInstallNativeCompatibility = function () {
    if (installed) throw fault("BRIDGE_ERROR", "SDK compatibility was installed twice");
    installed = true;
    function globalTimer(repeats) {
      return function (callback, ms) {
        if (typeof callback !== "function") throw fault("INVALID_ARGUMENT", "Timer callback must be a function");
        var args = Array.prototype.slice.call(arguments, 2);
        return timer(function () { return callback.apply(null, args); }, ms, repeats);
      };
    }
    global.setTimeout = globalTimer(false);
    global.setInterval = globalTimer(true);
    function observeRender(render) {
      return function (state, surface) { return observeTree(render(state, surface)); };
    }
    function surfaceOptions(options) {
      var copy = {};
      Object.keys(options || {}).forEach(function (key) {
        if (key === "content") copy[key] = observeTree(options[key]);
        else if (key === "render" && typeof options[key] === "function") copy[key] = observeRender(options[key]);
        else copy[key] = typeof options[key] === "function" ? observeCallback(options[key]) : options[key];
      });
      return copy;
    }
    function surfaceHandle(handle) {
      if (!handle) return handle;
      var update = handle.update, set = handle.set;
      handle.update = function (content) {
        try { return update(typeof content === "function" ? observeRender(content) : observeTree(content)); }
        catch (error) {
          // Core replaced its callback map before native validation. Keeping
          // the previous controls would leave them pointing at dead callbacks.
          try { handle.close(); } catch (closeError) { log("error", closeError); }
          throw error;
        }
      };
      handle.set = function (options) { return set(surfaceOptions(options)); };
      return handle;
    }
    function wrapSurface(original) {
      return function (options) {
        if (typeof options === "function") options = { render: options };
        else if (options == null) options = {};
        else if (typeof options !== "object" || Array.isArray(options) || options.type !== undefined) options = { content: options };
        return surfaceHandle(original(surfaceOptions(options)));
      };
    }
    ["window", "panel", "sheet", "screen"].forEach(function (name) { wg.ui[name] = wrapSurface(wg.ui[name]); });
    ["push", "present"].forEach(function (name) { wg.screens[name] = wrapSurface(wg.screens[name]); });
    wg.sleep = function (ms) {
      return new Promise(function (resolve, reject) {
        var id = wg.setTimeout(function () { delete sleepers[id]; resolve(); }, ms);
        sleepers[id] = reject;
      });
    };
    uiDispatch = global.__wgUIDispatch;
    global.__wgUIDispatch = function (surface, callback, payload) {
      if (stopped || stopping) return;
      if (surface !== "__toast") return uiDispatch(surface, callback, payload);
      var action = toastActions[callback];
      delete toastActions[callback];
      if (action && !(payload && payload.dismissed)) safeCallback(action, [payload]);
    };
    wg.ui.toast = function (text, options) {
      assertPermission("uiMutation", "ui.toast");
      if (typeof options === "string") options = { kind: options };
      options = options || {};
      var action = options.onAction || options.onTap, out = {};
      Object.keys(options).forEach(function (key) { if (typeof options[key] !== "function") out[key] = options[key]; });
      delete out.actionCallback;
      var id;
      if (typeof action === "function") {
        if (Object.keys(toastActions).length >= 4) throw fault("QUOTA_EXCEEDED", "Too many toast callbacks");
        id = "toast" + (++sequence);
        toastActions[id] = action;
        out.actionCallback = id;
        if (!out.action) out.action = "OK";
      }
      try { native.toast(String(text), out); }
      catch (error) { if (id) delete toastActions[id]; throw error; }
    };
    // The recovered Promise wrappers cannot reject native dialog failures.
    wg.ui.confirm = function (title, message, callback) {
      var promise = async("ui.confirm", [String(title || ""), String(message || "")]);
      if (typeof callback === "function") promise.then(function (value) { safeCallback(callback, [value]); }, function (error) { safeCallback(callback, [null, errorValue(error)]); });
      return promise;
    };
    var prompt = wg.ui.prompt;
    wg.ui.prompt = function (options, callback) {
      return prompt(options, function (value) { safeCallback(callback, [value]); });
    };
    wg.ui.menu = function (options, callback) {
      options = options || {};
      var items = options.items || [];
      var titles = items.map(function (item) { return typeof item === "string" ? item : String(item.title); });
      var promise = async("ui.actionSheet", [String(options.title || ""), String(options.message || ""), titles]);
      promise.then(function (index) {
        if (index < 0) safeCallback(options.onCancel, []);
        else if (items[index] && typeof items[index] === "object") safeCallback(items[index].onTap, []);
        safeCallback(callback, [index, index >= 0 ? titles[index] : null]);
      }, function (error) { safeCallback(callback, [null, errorValue(error)]); });
      return promise;
    };
    wg.httpGet = function (url, callback) { return legacyHTTP({ url: String(url) }, callback); };
    wg.httpPost = function (url, body, callback) { return legacyHTTP({ url: String(url), method: "POST", body: body }, callback); };
    wg.net.httpTiming = function (url, callback) { return resultCallback(request({ url: String(url), method: "HEAD" }), callback); };
    wg.reply = legacy("tg.reply");
    permissionTable.reply = "messages";
    wg.invoke = function (action, params, callback) {
      params = params || {};
      var peer = String(params.peerId || params.id || "");
      var messageId = Number(params.messageId || params.msgId || 0);
      var names = {
        "client.getMe": ["tg.getMe", []], "client.getPeer": ["tg.getPeer", [peer]],
        "client.getChatList": ["tg.getChatList", [Number(params.limit || 50)]],
        "client.getMessages": ["tg.getMessages", [peer, Number(params.limit || 50), Number(params.offsetId || 0)]],
        "client.getMessage": ["tg.getMessage", [peer, messageId]],
        "client.openChat": ["tg.openChat", [peer]],
        "client.sendText": ["tg.sendTextMessage", [peer, String(params.text || "")]],
        "client.reply": ["tg.reply", [peer, messageId, String(params.text || "")]],
        "client.sendFile": ["tg.sendFileMessage", [peer, String(params.path || ""), String(params.caption || ""), String(params.mimeType || "")]],
        "client.sendDice": ["tg.sendDiceMessage", [peer, String(params.emoji || "🎲")]],
        "client.sendLocation": ["tg.sendLocationMessage", [peer, Number(params.latitude), Number(params.longitude)]],
        "client.sendContact": ["tg.sendContactMessage", [peer, String(params.firstName || ""), String(params.lastName || ""), String(params.phone || params.phoneNumber || "")]],
        "client.editMessage": ["tg.editMessage", [peer, messageId, String(params.text || "")]],
        "client.deleteMessage": ["tg.deleteMessage", [peer, messageId, !!params.forEveryone]],
        "client.forwardMessage": ["tg.forwardMessage", [String(params.fromPeerId || ""), messageId, String(params.toPeerId || "")]],
        "client.pinMessage": ["tg.pinMessage", [peer, messageId, !!params.pinned]],
        "client.react": ["tg.reactToMessage", [peer, messageId, String(params.emoji || "")]],
        "client.markRead": ["tg.markChatAsRead", [peer]]
      };
      var call = Object.prototype.hasOwnProperty.call(names, action) ? names[action] : null;
      var promise = call ? async(call[0], call[1]) : Promise.reject(fault("UNSUPPORTED_API", "Unknown action " + action));
      if (typeof callback === "function") promise.then(function (value) { safeCallback(callback, [{ ok: true, result: value }]); }, function (error) { safeCallback(callback, [{ ok: false, error: errorValue(error) }]); });
      return promise;
    };
    wg.client.invoke = wg.invoke;
    wg.tg.invoke = function () { return Promise.reject(fault("UNSUPPORTED_API", "Raw MTProto invocation is not implemented")); };
    wg.tg.call = wg.tg.invoke;
    wg.services = unsupportedObject("services");
    wg.jobs = unsupportedObject("jobs");
    wg.intercept = unsupported("intercept");
    wg.removeIntercept = unsupported("removeIntercept");
    wg.ui.provide = unsupported("ui.provide");
    wg.ui.unprovide = unsupported("ui.unprovide");
    wg.tabs.add = unsupported("tabs.add");
    wg.tabs.remove = unsupported("tabs.remove");
    wg.ui.overlay = unsupported("ui.overlay");
    wg.wasm = { available: false, load: function () { return Promise.reject(fault("UNSUPPORTED_LANGUAGE", "WebAssembly execution is not enabled in this build")); } };
    ["addButton", "addLabel", "removeButton", "removeView", "clearButtons", "clearViews", "addHeaderButton", "addMenuButton", "removeHeaderButton"].forEach(function (name) { wg.chat[name] = unsupported("chat." + name); });
    ["addSettingsRow", "registerSettingsPage", "openSettingsPage", "addMenuItem"].forEach(function (name) { wg[name] = unsupported(name); });
    wg.getSettingsValue = function (page, control, fallback) { return wg.storage.get("settings:" + page + ":" + control, fallback); };
    wg.setSettingsValue = function (page, control, value) { return wg.storage.set("settings:" + page + ":" + control, value); };
    wg.chat.watchMessages = function (peerId, callback, limit) {
      assertPermission("messages", "chat.watchMessages");
      if (typeof callback !== "function") throw fault("INVALID_ARGUMENT", "watchMessages requires a callback");
      var id = "w" + (++sequence), event = "chat.messages." + id;
      var listener = on(event, callback);
      return async("tg.watchMessages", [String(peerId), id, limit || 50]).then(function () {
        var closed = false;
        return { id: id, close: function () {
          if (closed) return;
          closed = true;
          off(event, listener);
          if (!stopped && !stopping) sync("tg.unwatchMessages", [id]);
        } };
      }, function (error) { off(event, listener); throw error; });
    };

    // Keep recovered UI normalization/state and extension state/events. Repair
    // stream's per-instance async iterator and bound undrained event queues.
    var eventOn = wg.events.on, eventOff = wg.events.off;
    var sdkEvent = global.__wgSDKEvent, eventDepth = 0, deferredOff = [];
    function removeEvent(pattern, id) {
      if (eventDepth) deferredOff.push([pattern, id]);
      else eventOff(pattern, id);
    }
    global.__wgSDKEvent = function (name, payload) {
      eventDepth++;
      try { return sdkEvent(name, payload); }
      finally {
        eventDepth--;
        if (!eventDepth) {
          var removals = deferredOff; deferredOff = [];
          removals.forEach(function (entry) { eventOff(entry[0], entry[1]); });
        }
      }
    };
    wg.events.on = function (pattern, handler) {
      pattern = validateEvent(String(pattern));
      if (typeof handler !== "function") throw fault("INVALID_ARGUMENT", "Event handler must be a function");
      if (eventRegistrations.length >= 256) throw fault("QUOTA_EXCEEDED", "Too many SDK event handlers");
      var id = eventOn(pattern, observeCallback(handler));
      eventRegistrations.push({ pattern: String(pattern), id: id, handler: handler });
      return id;
    };
    wg.events.off = function (pattern, id) {
      pattern = legacyEvents[pattern] || String(pattern);
      if (id == null) removeEvent(pattern, null);
      else eventRegistrations.forEach(function (entry) {
        if (entry.pattern === pattern && (entry.id === id || entry.handler === id)) removeEvent(pattern, entry.id);
      });
      eventRegistrations = eventRegistrations.filter(function (entry) { return entry.pattern !== String(pattern) || (id != null && id !== entry.id && id !== entry.handler); });
    };
    wg.events.stream = function (pattern) {
      if (streams.length >= 64) throw fault("QUOTA_EXCEEDED", "Too many event streams");
      var queue = [], waiting = null, closed = false;
      var id = wg.events.on(pattern, function (payload, name) {
        var value = { name: name, args: [payload, name] };
        if (waiting) { var resolve = waiting; waiting = null; resolve({ value: value, done: false }); }
        else { if (queue.length === 256) queue.shift(); queue.push(value); }
      });
      var iterator = {
        next: function () {
          if (queue.length) return Promise.resolve({ value: queue.shift(), done: false });
          if (closed) return Promise.resolve({ done: true });
          if (waiting) return Promise.reject(fault("INVALID_ARGUMENT", "Only one stream.next() may be pending"));
          return new Promise(function (resolve) { waiting = resolve; });
        },
        return: function () {
          closed = true; queue = []; wg.events.off(pattern, id);
          streams = streams.filter(function (stream) { return stream !== iterator; });
          if (waiting) { waiting({ done: true }); waiting = null; }
          return Promise.resolve({ done: true });
        }
      };
      iterator[Symbol.asyncIterator] = function () { return this; };
      streams.push(iterator);
      return iterator;
    };
    var lifecycleEvents = ["onMessageReceive", "onOutgoingMessage", "onMessageSend", "onChatOpen", "onChatClose", "onUpdate", "onUpdates", "preRequest", "postRequest"].concat(Object.keys(legacyEvents));
    function trackLoad(result) {
      var promise = Promise.resolve(result);
      loadPromises.push(promise);
      promise.catch(function (error) {
        log("error", "onLoad: " + (error && error.stack || error));
        if (runtimeStarted && !stopped && !stopping) sync("runtime.failed", [String(error && error.stack || error)]);
      });
    }
    wg.registerPlugin = function (plugin) {
      assertActive();
      if (!plugin || (typeof plugin !== "object" && typeof plugin !== "function")) throw fault("INVALID_ARGUMENT", "Expected a plugin object");
      if (wg.__pluginInstances.indexOf(plugin) !== -1) return plugin;
      if (wg.__pluginInstances.length >= 32) throw fault("QUOTA_EXCEEDED", "Too many registered plugin instances");
      var methods = lifecycleEvents.filter(function (name) { return typeof plugin[name] === "function"; });
      methods.forEach(validateEvent);
      wg.__pluginInstances.push(plugin);
      try {
        methods.forEach(function (name) { on(name, function () { return plugin[name].apply(plugin, arguments); }); });
        if (typeof plugin.onLoad === "function") trackLoad(plugin.onLoad({ id: wg.pluginId, version: wg.pluginVersion, name: wg.pluginName || wg.pluginId }));
        return plugin;
      } catch (error) { trackLoad(Promise.reject(error)); throw error; }
    };
    wg.HookResult.continue = function (value) { return { action: "continue", strategy: "continue", value: value }; };
    ["cancel", "modify", "modifyFinal"].forEach(function (action) {
      wg.HookResult[action] = function (value) { return action === "cancel" ? { action: action, strategy: action, reason: value || "" } : { action: action, strategy: action, value: value }; };
    });
    var localCapabilities = [
      "BasePlugin", "registerPlugin", "log", "logLevel", "promisify", "on", "off", "hook",
      "ui.window", "ui.panel", "ui.sheet", "ui.screen", "ui.prompt", "ui.menu", "ui.toast", "ui.h", "ui.el",
      "ui.surfaces", "ui.closeAll", "ui.showToastWithAction", "toast", "screens.push", "screens.present",
      "state", "createStore", "events.on", "events.once", "events.off", "events.emit", "events.sticky", "events.stream",
      "chat.watchMessages", "files.read", "files.readBase64", "files.list", "bytes.from", "bytes.toString",
      "util.base64ToBytes", "util.bytesToBase64", "permissions.has", "getSettingsValue", "setSettingsValue",
      "settings.getValue", "settings.setValue", "capabilities.has", "capabilities.info", "capabilities.version", "capabilities.feature", "capabilities.iosAtLeast",
      "setTimeout", "setInterval", "clearTimeout", "clearInterval", "sleep", "reply", "getMe", "getPeer", "getChatList", "getMessages",
      "sendTextMessage", "sendFileMessage", "sendDiceMessage", "sendLocationMessage", "sendContactMessage", "editMessage", "deleteMessage",
      "forwardMessage", "pinMessage", "reactToMessage", "markChatAsRead", "openChat", "request", "fetch", "fetchJSON", "fetchPost", "fetchPostJSON", "httpGet", "httpPost", "net.httpTiming",
      "client.sendMessage", "client.sendFile", "client.sendDice", "client.sendLocation", "client.sendContact", "client.editMessage", "client.getMessages", "client.getPeer"
    ];
    ["VStack", "HStack", "Card", "Glass", "Blur", "Section", "Scroll", "List", "Text", "Button", "Row", "Toggle", "Slider", "Stepper", "TextField", "TextArea", "Segmented", "Progress", "Spinner", "Spacer", "Divider", "Icon", "Image"].forEach(function (name) {
      localCapabilities.push("ui." + name, "ui.el." + name);
    });
    wg.capabilities.has = function (path) {
      if (!path) return true;
      if (supported[path] && supported[path].exposed) return true;
      if (localCapabilities.some(function (key) { return key === path || key.indexOf(path + ".") === 0; })) return true;
      return Object.keys(supported).some(function (key) { return supported[key].exposed && key.indexOf(path + ".") === 0; });
    };
    wg.capabilities.info = function () { return sync("capabilities.info"); };
    wg.capabilities.feature = function (name) { return !!wg.capabilities.info().features[name]; };
    wg.permissions = { has: function (name) { return gate(String(name), "permissions.has"); } };
    wg.util.base64ToBytes = decodeBytes;
    wg.util.bytesToBase64 = function (value) { return encodeBytes(wg.bytes.from(value)); };
    // Core's failed CommonJS evaluations stay cached. Use the same native
    // resolver but evict on *every* load error, including JSON parse failures.
    var modules = Object.create(null);
    global.module.id = info.entry;
    global.module.filename = info.entry;
    global.module.loaded = false;
    global.__filename = info.entry;
    global.__dirname = info.entry.split("/").slice(0, -1).join("/");
    modules[info.entry] = global.module;
    function makeRequire(directory) {
      return function (name) {
        assertActive();
        if (name === "wg" || name === "whitegram") return global.wg;
        var resolved = native.resolveModule(directory, String(name));
        if (modules[resolved.path]) return modules[resolved.path].exports;
        if (Object.keys(modules).length >= 256) throw fault("QUOTA_EXCEEDED", "Too many modules");
        var module = { exports: {}, id: resolved.path, filename: resolved.path, loaded: false };
        modules[resolved.path] = module;
        try {
          if (resolved.kind === "json") module.exports = parse(resolved.source);
          else if (resolved.kind === "js") {
            new Function("module", "exports", "require", "__filename", "__dirname", "wg", resolved.source + "\n//# sourceURL=whitegram-plugin/" + encodeURI(resolved.path))
              .call(module.exports, module, module.exports, makeRequire(resolved.dir), resolved.path, resolved.dir, global.wg);
          } else throw fault("UNSUPPORTED_LANGUAGE", "Only JavaScript and JSON modules can be required");
          module.loaded = true;
          return module.exports;
        } catch (error) { delete modules[resolved.path]; throw error; }
      };
    }
    global.require = makeRequire(global.__dirname);
    // The recovered packer can fail after allocating several tokens. Scope
    // those temporary tokens to each high-level SDK call, including failures.
    manifest.forEach(function (entry) {
      if (!entry.exposed) return;
      var parts = entry.path.split("."), owner = wg;
      for (var i = 0; i < parts.length - 1; i++) owner = owner[parts[i]];
      var key = parts[parts.length - 1], original = owner[key];
      if (typeof original === "function" && original.__wgSDK) owner[key] = scopedBytes(original);
    });
    wg.events.emit = scopedBytes(wg.events.emit);
    wg.events.sticky = scopedBytes(wg.events.sticky);
    ["tg", "net", "files", "fs", "preferences", "clipboard", "ui", "chat", "settings", "menu"].forEach(function (key) {
      wg[key] = unsupportedObject(key, wg[key]);
    });
    global.wg = unsupportedObject("", wg);
    Object.freeze(permissionTable);
  };

  global.__wgFinishEntry = function () {
    if (finishedEntry) throw fault("BRIDGE_ERROR", "Entry already evaluated");
    finishedEntry = true;
    global.module.loaded = true;
    var plugin = global.module.exports;
    if (typeof plugin === "function") plugin = new plugin();
    if (plugin && (typeof plugin.onLoad === "function" || typeof plugin.onUnload === "function")) wg.registerPlugin(plugin);
    function waitForLoads(offset) {
      var end = loadPromises.length;
      return Promise.all(loadPromises.slice(offset, end)).then(function () {
        if (loadPromises.length > end) return waitForLoads(end);
      });
    }
    waitForLoads(0).then(function () {
      if (!stopped && !stopping) { sync("runtime.started"); runtimeStarted = true; }
    }, function (error) {
      if (!stopped && !stopping) sync("runtime.failed", [String(error && error.stack || error)]);
    });
  };
  global.__wgPrepareStop = function () {
    if (stopped || stopping) return;
    stopping = true;
    // Deliver closure through the recovered dispatcher, marking SDK handles
    // closed without asking the already-cancelled native host to close again.
    if (installed) {
      wg.ui.surfaces().slice().forEach(function (surface) { uiDispatch(surface.id, "__closed", null); });
      eventRegistrations.slice().forEach(function (entry) { wg.events.off(entry.pattern, entry.id); });
    }
    streams.slice().forEach(function (stream) { stream.return(); });
    Object.keys(sleepers).forEach(function (id) { sleepers[id](fault("PLUGIN_STOPPED", "Plugin stopped")); });
    sleepers = Object.create(null);
    toastActions = Object.create(null);
    // Rejections are delivered before releasing the context, so awaiters can
    // observe cancellation. All new operations already fail PLUGIN_STOPPED.
    Object.keys(pending).forEach(function (token) { pending[token].reject(fault("PLUGIN_STOPPED", "Plugin stopped")); });
    pending = Object.create(null);
    timers = Object.create(null);
    listeners = Object.create(null);
    sticky = Object.create(null);
    subscriptions = Object.create(null);
    bytePool = Object.create(null); byteCount = 0;
  };
  global.__wgDidStop = function () {
    stopped = true;
    loadPromises = [];
    wg.__pluginInstances = [];
    global.__wgSDKEvent = function () {};
    global.__wgUIDispatch = function () {};
  };
})(this);
