(function (global) {
  "use strict";
  var wg = global.wg;
  var S = wg.__sdk;
  if (!S) { return; }

  // ---------------------------------------------------------------- байты без base64
  // Значение из нативной стороны может нести маркер {__wgBytes:id}. Разворачиваем в Uint8Array.
  function revive(value) {
    if (value == null) return value;
    if (Array.isArray(value)) { for (var i = 0; i < value.length; i++) value[i] = revive(value[i]); return value; }
    if (typeof value === "object") {
      if (typeof value.__wgBytes === "number") { return S.takeBytes(value.__wgBytes); }
      for (var k in value) { if (Object.prototype.hasOwnProperty.call(value, k)) value[k] = revive(value[k]); }
    }
    return value;
  }
  // Аргументы в нативную сторону: Uint8Array/ArrayBuffer → маркер {__wgBytes:id}.
  function pack(value, seen) {
    if (value == null) return value;
    if (value instanceof Uint8Array || value instanceof ArrayBuffer ||
        (typeof ArrayBuffer !== "undefined" && ArrayBuffer.isView && ArrayBuffer.isView(value))) {
      var bytes = value instanceof Uint8Array ? value : new Uint8Array(value.buffer || value);
      return { __wgBytes: S.putBytes(bytes) };
    }
    if (typeof value !== "object") return value;
    seen = seen || [];
    if (seen.indexOf(value) !== -1) return null;
    seen.push(value);
    if (Array.isArray(value)) return value.map(function (v) { return pack(v, seen); });
    var out = {};
    for (var k in value) { if (Object.prototype.hasOwnProperty.call(value, k)) out[k] = pack(value[k], seen); }
    return out;
  }
  wg.bytes = {
    from: function (value) {
      if (value instanceof Uint8Array) return value;
      if (typeof value === "string") {
        var arr = new Uint8Array(value.length);
        for (var i = 0; i < value.length; i++) arr[i] = value.charCodeAt(i) & 0xff;
        return arr;
      }
      return new Uint8Array(value || 0);
    },
    toString: function (bytes) {
      var s = ""; var a = wg.bytes.from(bytes);
      for (var i = 0; i < a.length; i++) s += String.fromCharCode(a[i]);
      return s;
    }
  };

  // ---------------------------------------------------------------- вызовы реестра
  function callAsync(path, args) {
    return new Promise(function (resolve, reject) {
      S.call(path, pack(Array.prototype.slice.call(args)), function (value) { resolve(revive(value)); },
             function (error) { var e = new Error(error && error.message ? error.message : String(error)); e.code = error && error.code; reject(e); });
    });
  }
  function callSync(path, args) {
    var r = S.callSync(path, pack(Array.prototype.slice.call(args)));
    if (!r.ok) { var e = new Error(r.error && r.error.message ? r.error.message : "error"); e.code = r.error && r.error.code; throw e; }
    return revive(r.value);
  }

  // Разложить манифест реестра в объекты wg.tg.*, wg.postbox.* … по путям с точками.
  var manifest = S.manifest();
  var syncPaths = {};
  manifest.forEach(function (fn) { if (fn.sync) syncPaths[fn.path] = true; });
  function install(path) {
    var parts = path.split(".");
    var owner = wg;
    for (var i = 0; i < parts.length - 1; i++) {
      var key = parts[i];
      if (!owner[key] || typeof owner[key] !== "object") owner[key] = owner[key] || {};
      owner = owner[key];
    }
    var name = parts[parts.length - 1];
    // Не затираем уже существующую функцию старого API того же имени — реестр под другим путём.
    if (typeof owner[name] === "function" && !owner[name].__wgSDK) return;
    var isSync = syncPaths[path];
    var fn = isSync
      ? function () { return callSync(path, arguments); }
      : function () { return callAsync(path, arguments); };
    fn.__wgSDK = true;
    owner[name] = fn;
  }
  manifest.forEach(function (fn) { install(fn.path); });

  // ---------------------------------------------------------------- события
  var eventHandlers = {};   // pattern → [fn]
  var handlerSeq = 0;
  function normalizePattern(p) { return String(p); }
  wg.events = {
    on: function (pattern, handler) {
      pattern = normalizePattern(pattern);
      if (!eventHandlers[pattern]) { eventHandlers[pattern] = []; S.subscribe(pattern); }
      handler.__wgId = "eh" + (++handlerSeq);
      eventHandlers[pattern].push(handler);
      return handler.__wgId;
    },
    once: function (pattern, handler) {
      var id;
      var wrapper = function () { wg.events.off(pattern, id); return handler.apply(this, arguments); };
      id = wg.events.on(pattern, wrapper);
      return id;
    },
    off: function (pattern, id) {
      pattern = normalizePattern(pattern);
      var list = eventHandlers[pattern];
      if (!list) return;
      if (id == null) { delete eventHandlers[pattern]; S.unsubscribe(pattern); return; }
      eventHandlers[pattern] = list.filter(function (h) { return h.__wgId !== id && h !== id; });
      if (!eventHandlers[pattern].length) { delete eventHandlers[pattern]; S.unsubscribe(pattern); }
    },
    emit: function (name, payload, sticky) { S.emit(String(name), pack(payload || {}), !!sticky); },
    sticky: function (pattern) { return (S.sticky(String(pattern)) || []).map(function (e) { return { name: e.name, payload: revive(e.payload) }; }); },
    // Асинхронный поток обновлений: for await (const ev of wg.events.stream("tg.update")) {…}
    stream: function (pattern) {
      var queue = [], waiting = null, closed = false;
      var id = wg.events.on(pattern, function () {
        var ev = { name: pattern, args: Array.prototype.slice.call(arguments) };
        if (waiting) { var w = waiting; waiting = null; w({ value: ev, done: false }); } else queue.push(ev);
      });
      return {
        next: function () {
          if (queue.length) return Promise.resolve({ value: queue.shift(), done: false });
          if (closed) return Promise.resolve({ value: undefined, done: true });
          return new Promise(function (resolve) { waiting = resolve; });
        },
        return: function () { closed = true; wg.events.off(pattern, id); if (waiting) { waiting({ value: undefined, done: true }); waiting = null; } return Promise.resolve({ value: undefined, done: true }); },
        "@@asyncIterator": function () { return this; }
      };
    }
  };
  if (typeof Symbol !== "undefined" && Symbol.asyncIterator) {
    var proto = wg.events.stream("__proto_probe__");
    proto[Symbol.asyncIterator] = proto["@@asyncIterator"];
    proto.return();
  }
  // Нативная сторона доставляет событие сюда.
  global.__wgSDKEvent = function (name, payload) {
    payload = revive(payload);
    Object.keys(eventHandlers).forEach(function (pattern) {
      if (!matches(pattern, name)) return;
      eventHandlers[pattern].slice().forEach(function (handler) {
        try { handler(payload, name); } catch (e) { wg.__sdk.log("error", "event", "on(" + name + "): " + (e && e.stack || e), ""); }
      });
    });
  };
  function matches(pattern, name) {
    if (pattern === "*" || pattern === name) return true;
    if (pattern.slice(-2) === ".*") return name.indexOf(pattern.slice(0, -1)) === 0;
    if (pattern.slice(0, 2) === "*.") return name.slice(-(pattern.length - 1)) === pattern.slice(1);
    if (pattern.indexOf("*") === -1) return false;
    var parts = pattern.split("*"), idx = 0;
    for (var i = 0; i < parts.length; i++) {
      if (!parts[i]) continue;
      var at = name.indexOf(parts[i], idx);
      if (at === -1 || (i === 0 && at !== 0)) return false;
      idx = at + parts[i].length;
    }
    return parts[parts.length - 1] === "" || idx === name.length;
  }

  // ---------------------------------------------------------------- перехватчики
  var interceptors = {};   // id → fn
  var deferSeq = 0;
  wg.intercept = function (name, handler, options) {
    var id = "ic" + (++handlerSeq);
    interceptors[id] = { name: name, handler: handler };
    S.addInterceptor(id, String(name), options || {});
    return id;
  };
  wg.removeIntercept = function (id) { delete interceptors[id]; S.removeInterceptor(id); };
  wg.HookResult = wg.HookResult || {};
  wg.HookResult.continue = function (value) { return value === undefined ? { action: "continue" } : { action: "modify", value: value }; };
  wg.HookResult.cancel = function (reason) { return { action: "cancel", reason: reason || "" }; };
  wg.HookResult.modify = function (value) { return { action: "modify", value: value }; };
  wg.HookResult.modifyFinal = function (value) { return { action: "modifyFinal", value: value }; };
  wg.HookResult.replace = function (value) { return { action: "replace", value: value }; };
  // Нативная сторона зовёт цепочку.
  global.__wgSDKIntercept = function (id, name, payload) {
    var entry = interceptors[id];
    if (!entry) return { action: "continue" };
    var result;
    try { result = entry.handler(revive(payload), name); }
    catch (e) { wg.__sdk.log("error", "intercept", "intercept(" + name + "): " + (e && e.stack || e), ""); return { action: "continue" }; }
    if (result && typeof result.then === "function") {
      var token = "df" + (++deferSeq);
      result.then(function (r) { S.resolveDeferred(token, pack(normalizeHookResult(r))); },
                  function (err) { wg.__sdk.log("error", "intercept", name + " promise: " + err, ""); S.resolveDeferred(token, { action: "continue" }); });
      return { action: "defer", token: token };
    }
    return pack(normalizeHookResult(result));
  };
  function normalizeHookResult(r) {
    if (r == null) return { action: "continue" };
    if (typeof r === "object" && r.action) return r;
    if (typeof r === "object") return { action: "modify", value: r };
    if (r === false) return { action: "cancel" };
    return { action: "modify", value: r };
  }

  // ---------------------------------------------------------------- поставщики данных
  var providers = {};
  wg.ui = wg.ui || {};
  wg.ui.provide = function (slot, handler) {
    var id = "pv" + (++handlerSeq);
    providers[id] = handler;
    S.provide(String(slot), id);
    return id;
  };
  wg.ui.unprovide = function (slot) { S.unprovide(String(slot || "")); };
  global.__wgSDKProvide = function (id, slot, context) {
    var handler = providers[id];
    if (!handler) return null;
    try { return pack(handler(revive(context), slot)); }
    catch (e) { wg.__sdk.log("error", "provide", "provide(" + slot + "): " + (e && e.stack || e), ""); return null; }
  };

  // ---------------------------------------------------------------- межплагинные сервисы
  var serviceHandlers = {};   // handlerId → {methods}
  wg.services = wg.services || {};
  wg.services.provide = function (name, api, options) {
    options = options || {};
    var id = "svc" + (++handlerSeq);
    serviceHandlers[id] = api;
    S.call("services.provide", pack([name, options.version || "1.0", id]), function () {}, function () {});
    return id;
  };
  wg.services.unprovide = function (name) { S.callSync("services.unprovide", pack([name])); };
  wg.services.list = function () { return revive(S.callSync("services.list", []).value); };
  wg.services.call = function (name, method, args) { return callAsync("services.call", [name, method, args || []]); };
  wg.services.consume = function (name) {
    return new Proxy({}, { get: function (_, method) { return function () { return wg.services.call(name, String(method), Array.prototype.slice.call(arguments)); }; } });
  };
  // Нативная сторона зовёт метод сервиса; результат (в т.ч. Promise) отдаём через resolveService.
  global.__wgServiceCall = function (handlerId, method, args, token, consumer) {
    var api = serviceHandlers[handlerId];
    if (!api || typeof api[method] !== "function") { S.resolveService(token, false, null, "нет метода " + method); return; }
    try {
      var result = api[method].apply(api, revive(args).concat([{ consumer: consumer }]));
      if (result && typeof result.then === "function") {
        result.then(function (v) { S.resolveService(token, true, pack(v), ""); }, function (e) { S.resolveService(token, false, null, String(e)); });
      } else {
        S.resolveService(token, true, pack(result), "");
      }
    } catch (e) { S.resolveService(token, false, null, String(e && e.stack || e)); }
  };

  // ---------------------------------------------------------------- задания планировщика
  var jobHandlers = {};
  wg.jobs = wg.jobs || {};
  wg.jobs.on = function (jobName, handler) { jobHandlers[String(jobName)] = handler; };
  global.__wgSDKJob = function (jobName, payload) {
    var handler = jobHandlers[jobName];
    if (handler) { try { handler(revive(payload)); } catch (e) { wg.__sdk.log("error", "scheduler", jobName + ": " + (e && e.stack || e), ""); } }
  };

  // ---------------------------------------------------------------- capabilities
  wg.capabilities = wg.capabilities || {};
  var caps = null;
  function loadCaps() { if (!caps) { try { caps = callSync("capabilities.info", []); } catch (e) { caps = { subsystems: {}, functions: [] }; } } return caps; }
  wg.capabilities.has = function (path) {
    var c = loadCaps();
    if (!path) return true;
    if (c.functions && c.functions.indexOf(path) !== -1) return true;
    if (c.subsystems && c.subsystems[path]) return true;
    if (c.features && c.features[path]) return true;
    var parts = String(path).split("."), owner = wg;
    for (var i = 0; i < parts.length; i++) { owner = owner ? owner[parts[i]] : undefined; }
    return typeof owner === "function" || typeof owner === "object";
  };
  wg.capabilities.version = function (subsystem) { var c = loadCaps(); return (c.subsystems && c.subsystems[subsystem]) || null; };
  wg.capabilities.info = function () { return loadCaps(); };
  wg.capabilities.feature = function (name) { var c = loadCaps(); return !!(c.features && c.features[name]); };
  wg.capabilities.iosAtLeast = function (v) { var c = loadCaps(); return compareVer(c.ios || "0", String(v)) >= 0; };
  wg.capabilities.telegramLayer = function () { return loadCaps().telegramLayer || 0; };
  function compareVer(a, b) { var pa = a.split("."), pb = b.split("."); for (var i = 0; i < 3; i++) { var x = parseInt(pa[i] || 0, 10), y = parseInt(pb[i] || 0, 10); if (x !== y) return x < y ? -1 : 1; } return 0; }

  // ---------------------------------------------------------------- реактивное состояние
  wg.state = wg.createStore = function (initial) {
    var value = initial || {};
    var watchers = [];
    var computedCache = {};
    function notify(changed) {
      watchers.slice().forEach(function (w) {
        if (!w.keys || w.keys.some(function (k) { return changed.indexOf(k) !== -1; })) {
          try { w.fn(value); } catch (e) { wg.__sdk.log("error", "state", String(e), ""); }
        }
      });
    }
    var batching = false, pending = [];
    return {
      get: function (key) { return key == null ? value : value[key]; },
      set: function (key, v) {
        var changed = [];
        if (typeof key === "object") { for (var k in key) { if (value[k] !== key[k]) { value[k] = key[k]; changed.push(k); } } }
        else if (value[key] !== v) { value[key] = v; changed.push(key); }
        if (!changed.length) return;
        if (batching) { pending = pending.concat(changed); } else notify(changed);
      },
      update: function (fn) { fn(value); notify(Object.keys(value)); },
      batch: function (fn) { batching = true; pending = []; try { fn(); } finally { batching = false; if (pending.length) notify(pending); } },
      watch: function (fn, keys) { var w = { fn: fn, keys: keys }; watchers.push(w); return function () { watchers = watchers.filter(function (x) { return x !== w; }); }; },
      computed: function (name, fn) { Object.defineProperty(this, name, { get: function () { return fn(value); }, configurable: true }); return this; },
      persist: function (storageKey) {
        var saved = wg.storage && wg.storage.get ? wg.storage.get(storageKey) : null;
        if (saved) { try { var obj = typeof saved === "string" ? JSON.parse(saved) : saved; for (var k in obj) value[k] = obj[k]; } catch (e) {} }
        this.watch(function (v) { try { wg.storage.set(storageKey, JSON.stringify(v)); } catch (e) {} });
        return this;
      },
      snapshot: function () { return JSON.parse(JSON.stringify(value)); }
    };
  };

  // ---------------------------------------------------------------- совместимость со старым API
  // Старые имена SDK 5 остаются рабочими, но перенаправлены на реестр 6.0.
  if (wg.tg) {
    wg.tg.invoke = wg.tg.invoke || function (method, params, extra) { return callAsync("tg.invoke", [method, params, extra]); };
    wg.tg.call = wg.tg.invoke;
  }
  // Расширяем доступ к другим языкам: вызовы wg.lang.* уже есть из старой надстройки.
  wg.__sdkReady = true;
})(this);