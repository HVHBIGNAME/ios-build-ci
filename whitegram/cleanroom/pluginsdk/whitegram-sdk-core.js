(function (global) {
  "use strict";
  var wg = global.wg;
  var N = wg.__native;
  var NET = wg.__net;
  var seq = 0;
  function isFn(v) { return typeof v === "function"; }
  function nextId(prefix) { seq += 1; return prefix + seq; }

  // ---------------------------------------------------------------- console, таймеры
  function fmt(args) {
    return Array.prototype.map.call(args, function (a) {
      if (typeof a === "string") return a;
      if (a instanceof Error) return a.stack ? (a.message + "\n" + a.stack) : String(a);
      try { return JSON.stringify(a); } catch (e) { return String(a); }
    }).join(" ");
  }
  global.console = {
    log: function () { wg.logLevel("info", fmt(arguments)); },
    info: function () { wg.logLevel("info", fmt(arguments)); },
    debug: function () { wg.logLevel("debug", fmt(arguments)); },
    warn: function () { wg.logLevel("warn", fmt(arguments)); },
    error: function () { wg.logLevel("error", fmt(arguments)); }
  };
  if (!isFn(global.setTimeout)) {
    global.setTimeout = function (fn, ms) {
      var args = Array.prototype.slice.call(arguments, 2);
      return wg.setTimeout(function () { fn.apply(null, args); }, Number(ms) || 0);
    };
    global.clearTimeout = function (id) { wg.clearTimeout(Number(id)); };
    global.setInterval = function (fn, ms) {
      var args = Array.prototype.slice.call(arguments, 2);
      return wg.setInterval(function () { fn.apply(null, args); }, Number(ms) || 0);
    };
    global.clearInterval = function (id) { wg.clearInterval(Number(id)); };
  }
  wg.sleep = function (ms) { return new Promise(function (resolve) { wg.setTimeout(resolve, Number(ms) || 0); }); };
  wg.promisify = function (fn, self) {
    return function () {
      var args = Array.prototype.slice.call(arguments);
      return new Promise(function (resolve) {
        args.push(function () { resolve(arguments.length > 1 ? Array.prototype.slice.call(arguments) : arguments[0]); });
        fn.apply(self || wg, args);
      });
    };
  };
  function withPromise(run, cb) {
    return new Promise(function (resolve) {
      run(function (result) {
        resolve(result);
        if (isFn(cb)) { try { cb(result); } catch (e) { console.error(e); } }
      });
    });
  }

  // ---------------------------------------------------------------- дерево интерфейса
  function flat(list) {
    var out = [];
    (Array.isArray(list) ? list : [list]).forEach(function (item) {
      if (Array.isArray(item)) out = out.concat(flat(item)); else out.push(item);
    });
    return out;
  }
  // ctx: { callbacks, state, rerender }
  function normalize(node, ctx) {
    if (node === null || node === undefined || node === false || node === true) return null;
    if (typeof node === "string" || typeof node === "number") return { type: "text", props: { text: String(node) }, children: [] };
    if (Array.isArray(node)) return { type: "vstack", props: {}, children: normChildren(node, ctx) };
    if (typeof node !== "object") return null;
    var src = (node.props && typeof node.props === "object") ? node.props : node;
    var props = {};
    Object.keys(src).forEach(function (k) {
      if (k === "type" || k === "children" || (src === node && k === "props")) return;
      var v = src[k];
      if (v === undefined) return;
      if (isFn(v)) { var id = nextId("c"); ctx.callbacks[id] = v; props[k] = "__cb:" + id; return; }
      props[k] = v;
    });
    // bind: "ключ" — значение элемента берётся из состояния поверхности и пишется обратно.
    if (typeof props.bind === "string" && ctx.state) {
      var key = props.bind;
      if (props.value === undefined) props.value = ctx.state[key];
      var original = props.onChange ? ctx.callbacks[props.onChange.slice(5)] : null;
      var bindId = nextId("c");
      ctx.callbacks[bindId] = function (value, handle, raw) {
        ctx.state[key] = value;
        if (original) original(value, handle, raw);
        if (src.rerender !== false && ctx.rerender) ctx.rerender();
      };
      props.onChange = "__cb:" + bindId;
    }
    return { type: String(node.type || "vstack").toLowerCase(), props: props, children: normChildren(node.children || [], ctx) };
  }
  function normChildren(list, ctx) {
    var out = [];
    flat(list).forEach(function (child) { var n = normalize(child, ctx); if (n) out.push(n); });
    return out;
  }
  function container(type) {
    return function (a, b) {
      if (Array.isArray(a)) return { type: type, props: b || {}, children: a };
      if (a && typeof a === "object" && a.type === undefined) {
        return { type: type, props: a, children: b === undefined ? [] : (Array.isArray(b) ? b : Array.prototype.slice.call(arguments, 1)) };
      }
      return { type: type, props: {}, children: Array.prototype.slice.call(arguments) };
    };
  }
  function leaf(type, key) {
    return function (a, b) {
      if (a && typeof a === "object" && !Array.isArray(a)) return { type: type, props: a, children: [] };
      var p = {};
      if (b && typeof b === "object") Object.keys(b).forEach(function (k) { p[k] = b[k]; });
      if (isFn(b)) p.onTap = b;
      if (a !== undefined && a !== null) p[key] = a;
      return { type: type, props: p, children: [] };
    };
  }
  var el = {
    VStack: container("vstack"), HStack: container("hstack"), ZStack: container("zstack"),
    Glass: container("glass"), Blur: container("blur"), Card: container("card"),
    Scroll: container("scroll"), List: container("list"),
    Section: function (a, b) {
      if (typeof a === "string") return { type: "section", props: { header: a }, children: b || [] };
      return container("section").apply(null, arguments);
    },
    Text: leaf("text", "text"), Button: leaf("button", "title"), Image: leaf("image", "src"),
    Icon: leaf("icon", "symbol"), Toggle: leaf("toggle", "title"), Slider: leaf("slider", "title"),
    TextField: leaf("textfield", "placeholder"), TextArea: leaf("textarea", "placeholder"),
    Stepper: leaf("stepper", "title"), Progress: leaf("progress", "value"), Spinner: leaf("spinner", "size"),
    Web: leaf("web", "html"), Row: leaf("row", "title"),
    Segmented: function (options, props) {
      var p = {}; Object.keys(props || {}).forEach(function (k) { p[k] = props[k]; });
      p.options = options; return { type: "segmented", props: p, children: [] };
    },
    Spacer: function (p) { return { type: "spacer", props: typeof p === "number" ? { minLength: p } : (p || {}), children: [] }; },
    Divider: function () { return { type: "divider", props: {}, children: [] }; }
  };

  // ---------------------------------------------------------------- поверхности
  var surfaces = {};
  var chatBarCallbacks = {};
  var headerCallbacks = {};
  var toastCallbacks = {};

  function splitOptions(options, entry) {
    var out = {};
    Object.keys(options || {}).forEach(function (k) {
      var v = options[k];
      if (k === "content" || k === "render" || k === "state") return;
      if (isFn(v)) { entry.handlers[k] = v; return; }
      if (v !== undefined) out[k] = v;
    });
    return out;
  }
  function renderEntry(entry) {
    entry.callbacks = {};
    var content;
    try {
      content = entry.render ? entry.render(entry.state, entry.handle) : entry.content;
    } catch (e) {
      console.error("render error:", e);
      content = el.Text("⚠️ " + String(e), { color: "destructive" });
    }
    return normalize(content, { callbacks: entry.callbacks, state: entry.state, rerender: function () { entry.handle.update(); } });
  }
  function makeSurface(kind, options) {
    if (options === undefined || options === null) options = {};
    if (typeof options !== "object" || Array.isArray(options) || options.type !== undefined) options = { content: options };
    if (isFn(options)) options = { render: options };
    var entry = {
      kind: kind, handlers: {}, callbacks: {}, state: options.state || {},
      render: isFn(options.render) ? options.render : null, content: options.content,
      handle: null, closed: false
    };
    var handle = {
      kind: kind,
      id: null,
      get state() { return entry.state; },
      get isClosed() { return entry.closed; },
      update: function (content) {
        if (entry.closed) return false;
        if (content !== undefined) {
          if (isFn(content)) entry.render = content; else { entry.render = null; entry.content = content; }
        }
        return N.updateSurface(handle.id, renderEntry(entry));
      },
      setState: function (patch) {
        if (isFn(patch)) patch = patch(entry.state);
        Object.keys(patch || {}).forEach(function (k) { entry.state[k] = patch[k]; });
        return handle.update();
      },
      set: function (opts) { return N.setSurfaceOptions(handle.id, splitOptions(opts, entry)); },
      setTitle: function (title) { return N.setSurfaceOptions(handle.id, { title: String(title) }); },
      show: function () { N.setSurfaceVisible(handle.id, true); },
      hide: function () { N.setSurfaceVisible(handle.id, false); },
      close: function () { if (!entry.closed) N.closeSurface(handle.id); },
      info: function () { return N.surfaceInfo(handle.id); }
    };
    entry.handle = handle;
    var tree = renderEntry(entry);
    var id = N.createSurface(kind, splitOptions(options, entry), tree);
    if (!id) return null;
    handle.id = id;
    surfaces[id] = entry;
    return handle;
  }

  global.__wgUIDispatch = function (surfaceId, callbackId, payload) {
    try {
      if (surfaceId === "__chatbar") { var f = chatBarCallbacks[callbackId]; if (f) f(payload); return; }
      if (surfaceId === "__header") { var h = headerCallbacks[callbackId]; if (h) h(payload); return; }
      if (surfaceId === "__toast") { var t = toastCallbacks[callbackId]; delete toastCallbacks[callbackId]; if (t) t(payload); return; }
      var entry = surfaces[surfaceId];
      if (!entry) return;
      if (callbackId === "__closed") {
        entry.closed = true;
        delete surfaces[surfaceId];
        var onClose = entry.handlers.onClose || entry.handlers.onDismiss;
        if (onClose) onClose(entry.handle);
        return;
      }
      if (callbackId === "__moved") { if (entry.handlers.onMove) entry.handlers.onMove(payload, entry.handle); return; }
      var fn = entry.callbacks[callbackId];
      if (fn) fn(payload && payload.value !== undefined ? payload.value : payload, entry.handle, payload);
    } catch (e) {
      console.error("UI callback error:", e);
    }
  };

  var ui = wg.ui || (wg.ui = {});
  ui.el = el;
  Object.keys(el).forEach(function (k) { ui[k] = el[k]; });
  ui.h = function (type, props, children) { return { type: String(type), props: props || {}, children: children || [] }; };
  ui.window = function (options) { return makeSurface("window", options); };
  ui.panel = ui.window;
  ui.overlay = function (options) { return makeSurface("overlay", options); };
  ui.sheet = function (options) { return makeSurface("sheet", options); };
  // Полноэкранный плагин-экран: то же дерево/состояние/колбэки, но вид забирает контроллер.
  ui.screen = function (options) { return makeSurface("screen", options); };

  // ---------------------------------------------------------------- экраны и вкладки
  wg.screens = wg.screens || {};
  // wg.screens.push(options) — втолкнуть экран в текущую навигацию.
  wg.screens.push = function (options) {
    var handle = makeSurface("screen", options);
    if (handle) N.pushScreen(handle.id, false);
    return handle;
  };
  // wg.screens.present(options) — показать экран модально.
  wg.screens.present = function (options) {
    var handle = makeSurface("screen", options);
    if (handle) N.pushScreen(handle.id, true);
    return handle;
  };
  wg.tabs = wg.tabs || {};
  // wg.tabs.add({ tabId, title, icon, selectedIcon, render|content, state }) — вкладка в Tab Bar.
  wg.tabs.add = function (options) {
    options = options || {};
    var handle = makeSurface("screen", options);
    if (!handle) return null;
    var tabId = options.tabId || options.id || handle.id;
    N.registerTab(handle.id, { tabId: tabId, title: String(options.title || "Plugin"),
                               icon: String(options.icon || "puzzlepiece.extension"),
                               selectedIcon: options.selectedIcon ? String(options.selectedIcon) : undefined });
    handle.tabId = tabId;
    handle.remove = function () { N.unregisterTab(tabId); handle.close(); };
    return handle;
  };
  wg.tabs.remove = function (tabId) { N.unregisterTab(String(tabId)); };
  ui.closeAll = function () { Object.keys(surfaces).forEach(function (id) { N.closeSurface(id); }); };
  ui.surfaces = function () { return Object.keys(surfaces).map(function (id) { return surfaces[id].handle; }); };
  ui.theme = function () { return N.theme(); };
  ui.keyboardHeight = function () { return N.keyboardHeight(); };
  ui.haptic = function (style) { N.haptic(String(style || "light")); };

  ui.toast = function (text, options) {
    if (typeof options === "string") options = { kind: options };
    options = options || {};
    var o = {};
    Object.keys(options).forEach(function (k) { if (!isFn(options[k])) o[k] = options[k]; });
    var action = options.onAction || options.onTap;
    if (isFn(action)) {
      var id = nextId("t");
      toastCallbacks[id] = action;
      o.actionCallback = id;
      if (!o.action) o.action = "OK";
    }
    N.toast(String(text), o);
  };
  wg.toast = function (text, options) { ui.toast(text, options); };
  ui.showToastWithAction = function (text, actionTitle, callback) { ui.toast(text, { action: actionTitle || "OK", onAction: callback }); };

  var nativeConfirm = ui.confirm;
  ui.confirm = function (title, message, callback) {
    return new Promise(function (resolve) {
      nativeConfirm(String(title || ""), String(message || ""), function (ok) {
        resolve(!!ok);
        if (isFn(callback)) callback(!!ok);
      });
    });
  };
  var nativeActionSheet = ui.actionSheet;
  ui.menu = function (options, callback) {
    options = options || {};
    var items = options.items || [];
    return new Promise(function (resolve) {
      nativeActionSheet(String(options.title || ""), String(options.message || ""), items.map(function (item) {
        return typeof item === "string" ? item : String(item.title);
      }), function (index, title) {
        var item = index >= 0 ? items[index] : null;
        if (item && isFn(item.onTap)) item.onTap();
        if (index < 0 && isFn(options.onCancel)) options.onCancel();
        resolve(index);
        if (isFn(callback)) callback(index, title);
      });
    });
  };
  ui.prompt = function (options, callback) {
    if (typeof options === "string") options = { title: options };
    options = options || {};
    var value = options.value !== undefined ? String(options.value) : "";
    return new Promise(function (resolve) {
      var done = false;
      var surface = null;
      function finish(result) {
        if (done) return;
        done = true;
        resolve(result);
        if (isFn(callback)) callback(result);
        if (surface) surface.close();
      }
      surface = makeSurface("window", {
        title: options.title || wg.pluginName,
        anchor: "center", modal: true, width: options.width || 320,
        material: options.material || "glass",
        onClose: function () { finish(null); },
        render: function () {
          return el.VStack({ spacing: 12 }, [
            options.message ? el.Text(String(options.message), { secondary: true, font: "subheadline" }) : null,
            el.TextField({
              placeholder: options.placeholder || "", value: value, secure: !!options.secure,
              keyboard: options.keyboard, autofocus: true, returnKey: "done",
              onChange: function (v) { value = v; },
              onSubmit: function (v) { value = v; finish(value); }
            }),
            el.HStack({ spacing: 10, distribution: "equal" }, [
              el.Button(options.cancelTitle || "Отмена", { style: "gray", onTap: function () { finish(null); } }),
              el.Button(options.okTitle || "OK", { style: "filled", onTap: function () { finish(value); } })
            ])
          ]);
        }
      });
    });
  };

  // ---------------------------------------------------------------- чат
  var chat = wg.chat || (wg.chat = {});
  chat.addButton = function (config) {
    config = config || {};
    var id = String(config.id || nextId("b"));
    var callback = config.onTap || config.onPress || config.action;
    if (isFn(callback)) chatBarCallbacks[id] = callback; else delete chatBarCallbacks[id];
    N.chatBarAdd({
      id: id,
      title: String(config.title || config.text || ""),
      icon: String(config.icon || ""),
      tint: String(config.tint || config.color || config.bgColor || ""),
      style: String(config.style || "glass"),
      hookName: String(config.hookName || ""),
      hasCallback: isFn(callback),
      peerIds: (config.peerIds || (config.peerId ? [config.peerId] : [])).map(String),
      chatTypes: (config.chatTypes || []).map(String),
      priority: Number(config.priority || 0)
    });
    return id;
  };
  chat.addLabel = function (config) {
    config = config || {};
    var copy = {};
    Object.keys(config).forEach(function (k) { copy[k] = config[k]; });
    copy.style = "label";
    return chat.addButton(copy);
  };
  chat.removeButton = function (id) { delete chatBarCallbacks[String(id)]; N.chatBarRemove(String(id)); };
  chat.removeView = chat.removeButton;
  chat.clearButtons = function () { chatBarCallbacks = {}; N.chatBarRemove(""); };
  chat.clearViews = chat.clearButtons;
  chat.addHeaderButton = function (config) {
    config = config || {};
    var id = String(config.id || nextId("h"));
    var callback = config.onTap || config.onPress || config.action;
    if (isFn(callback)) headerCallbacks[id] = callback;
    N.headerButtonAdd({ id: id, icon: String(config.icon || ""), title: String(config.title || "") });
    return id;
  };
  chat.addMenuButton = chat.addHeaderButton;
  chat.removeHeaderButton = function (id) { delete headerCallbacks[String(id)]; N.headerButtonRemove(String(id)); };

  // ---------------------------------------------------------------- сеть
  wg.net = {
    tcpPing: function (host, port, options, cb) {
      if (isFn(options)) { cb = options; options = {}; }
      return withPromise(function (done) { NET.tcpPing(String(host), Number(port || 443), options || {}, done); }, cb);
    },
    ping: function (host, options, cb) {
      if (isFn(options)) { cb = options; options = {}; }
      return withPromise(function (done) { NET.ping(String(host), options || {}, done); }, cb);
    },
    dns: function (host, cb) { return withPromise(function (done) { NET.dns(String(host), done); }, cb); },
    httpTiming: function (url, cb) { return withPromise(function (done) { NET.httpTiming(String(url), done); }, cb); },
    status: function () { return NET.status(); },
    connect: function (config, handlers) {
      handlers = handlers || {};
      var id = NET.connect(config || {}, handlers);
      if (id < 0) return null;
      return {
        id: id,
        send: function (data) { return NET.send(id, typeof data === "string" ? data : JSON.stringify(data), {}); },
        sendBase64: function (data) { return NET.send(id, String(data), { base64: true }); },
        close: function () { NET.close(id); }
      };
    }
  };

  // ---------------------------------------------------------------- модули пакета
  var moduleCache = {};
  function makeRequire(dir) {
    return function require(name) {
      name = String(name);
      if (name === "wg" || name === "whitegram") return wg;
      var r = N.resolveModule(dir, name);
      if (!r || !r.path) throw new Error("Cannot find module '" + name + "'" + (dir ? " from '" + dir + "'" : ""));
      if (moduleCache[r.path]) return moduleCache[r.path].exports;
      var module = { exports: {}, id: r.path, filename: r.path, loaded: false };
      moduleCache[r.path] = module;
      if (r.kind === "json") {
        module.exports = JSON.parse(r.source);
      } else if (r.kind === "js" || r.kind === "typescript") {
        var source = r.source;
        if (r.kind === "typescript") {
          var compiled = wg.__lang.transpileTypeScript(r.source, r.path);
          if (!compiled.ok) { delete moduleCache[r.path]; throw new Error(compiled.error); }
          source = compiled.result;
        }
        var fn = new Function("module", "exports", "require", "__filename", "__dirname", "wg", source + "\n//# sourceURL=" + r.path);
        fn.call(module.exports, module, module.exports, makeRequire(r.dir), r.path, r.dir, wg);
      } else if (wg.lang && wg.lang[r.kind]) {
        // require("./logic.py") — модуль на другом языке: вызовы его функций идут через рантайм.
        module.exports = wg.lang[r.kind].module(r.path, r.source);
      } else {
        module.exports = r.source;
      }
      module.loaded = true;
      return module.exports;
    };
  }
  global.require = makeRequire("");
  global.module = { exports: {} };
  global.exports = global.module.exports;
  wg.files = {
    list: function () { return N.listPackageFiles(); },
    read: function (path) { var v = N.readPackageFile(String(path), false); return v === null ? null : v; },
    readBase64: function (path) { var v = N.readPackageFile(String(path), true); return v === null ? null : v; }
  };

  // ---------------------------------------------------------------- WebAssembly
  function base64ToBytes(b64) {
    var alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    var lookup = {};
    for (var i = 0; i < alphabet.length; i++) lookup[alphabet.charAt(i)] = i;
    b64 = b64.replace(/[^A-Za-z0-9+/]/g, "");
    var out = new Uint8Array(Math.floor(b64.length * 3 / 4));
    var o = 0;
    for (var j = 0; j < b64.length; j += 4) {
      var n = (lookup[b64.charAt(j)] << 18) | (lookup[b64.charAt(j + 1)] << 12) | ((lookup[b64.charAt(j + 2)] || 0) << 6) | (lookup[b64.charAt(j + 3)] || 0);
      if (o < out.length) out[o++] = (n >> 16) & 255;
      if (o < out.length && j + 2 < b64.length) out[o++] = (n >> 8) & 255;
      if (o < out.length && j + 3 < b64.length) out[o++] = n & 255;
    }
    return out;
  }
  wg.util = wg.util || {};
  wg.util.base64ToBytes = base64ToBytes;
  wg.wasm = {
    available: typeof WebAssembly === "object" && isFn(WebAssembly.instantiate),
    load: function (path, imports) {
      if (!wg.wasm.available) return Promise.reject(new Error("WebAssembly недоступен в движке плагинов этой версии iOS — используйте wg.lang"));
      var b64 = N.readPackageFile(String(path), true);
      if (!b64) return Promise.reject(new Error("Файл не найден в пакете: " + path));
      return WebAssembly.instantiate(base64ToBytes(b64), imports || {}).then(function (r) { return r.instance; });
    }
  };

  // ---------------------------------------------------------------- другие языки (wg.lang)
  var L = wg.__lang;
  var langEvents = {};
  function safe(value) {
    if (value === undefined) return null;
    try { return JSON.parse(JSON.stringify(value)); } catch (e) { return String(value); }
  }
  function langRequest(lang, op, payload) {
    return new Promise(function (resolve, reject) {
      L.request(lang, op, payload || {}, function (response) {
        if (response && response.ok) resolve(response.result);
        else reject(new Error((response && response.error) || ("Ошибка " + lang)));
      });
    });
  }
  function makeLanguage(id) {
    var api = {
      id: id,
      get installed() { return L.isInstalled(id); },
      // Выполнить код; результат — значение последнего выражения (Python) / return (Lua…).
      run: function (code, options) {
        options = options || {};
        return langRequest(id, "run", { code: String(code), filename: options.filename || ("<" + wg.pluginId + ">") });
      },
      // Вызвать функцию: wg.lang.python.call("tools.ping", "1.1.1.1", 443)
      call: function (fn) {
        return langRequest(id, "call", { fn: String(fn), args: safe(Array.prototype.slice.call(arguments, 1)) || [] });
      },
      callWith: function (fn, args, kwargs) {
        return langRequest(id, "call", { fn: String(fn), args: safe(args || []) || [], kwargs: safe(kwargs || {}) || {} });
      },
      import: function (path) { return langRequest(id, "import", { path: String(path), module: String(path) }); },
      // Python: pip install; остальные языки пакетов не ставят.
      install: function (packages, options) {
        if (!Array.isArray(packages)) packages = [packages];
        return langRequest(id, "install", { packages: packages.map(String), upgrade: !!(options && options.upgrade) });
      },
      packages: function () { return langRequest(id, "packages", {}); },
      reset: function () { return langRequest(id, "reset", {}); },
      on: function (event, handler) {
        var map = langEvents[id] || (langEvents[id] = {});
        (map[event] || (map[event] = [])).push(handler);
        return api;
      },
      // Модуль другого языка как объект JS: const tools = require("./tools.py");
      // await tools.ping("1.1.1.1") — вызов функции ping из tools.py.
      module: function (path) {
        var name = String(path).replace(/\.[A-Za-z]+$/, "").replace(/\//g, ".");
        var imported = null;
        function ensure() { return imported || (imported = api.import(path)); }
        function qualified(prop) {
          if (id === "python") return name + "." + prop;
          if (id === "lua") return name.split(".").pop() + "." + prop;
          return prop;
        }
        return new Proxy({}, {
          get: function (_, prop) {
            if (typeof prop !== "string" || prop === "then" || prop === "toJSON") return undefined;
            if (prop === "ready") return ensure();
            return function () {
              var args = Array.prototype.slice.call(arguments);
              return ensure().then(function () { return langRequest(id, "call", { fn: qualified(prop), args: safe(args) || [] }); });
            };
          }
        });
      }
    };
    return api;
  }
  wg.lang = {
    python: makeLanguage("python"),
    lua: makeLanguage("lua"),
    ruby: makeLanguage("ruby"),
    go: makeLanguage("go"),
    typescript: {
      id: "typescript",
      get installed() { return L.isInstalled("typescript"); },
      transpile: function (source, fileName) {
        var r = L.transpileTypeScript(String(source), String(fileName || "module.ts"));
        if (!r.ok) throw new Error(r.error);
        return r.result;
      }
    },
    available: function () { return L.installed(); },
    isInstalled: function (id) { return L.isInstalled(String(id)); },
    // Убедиться, что языки установлены; если нет — предложить пользователю поставить.
    require: function (ids) {
      if (!Array.isArray(ids)) ids = [ids];
      return new Promise(function (resolve) { L.promptInstall(ids.map(String), function (ok) { resolve(!!ok); }); });
    }
  };
  wg.lang.py = wg.lang.python;
  wg.lang.ts = wg.lang.typescript;

  // Функции старого API с колбэком последним аргументом: из других языков их результат
  // приходит так же, как у Promise.
  var callbackStyle = {
    getMe: 1, getChatList: 1, getMessages: 1, getPeer: 1, sendTextMessage: 1, sendFileMessage: 1,
    sendDiceMessage: 1, sendLocationMessage: 1, sendContactMessage: 1, fetch: 1, fetchPost: 1,
    fetchJSON: 1, fetchPostJSON: 1, request: 1, downloadFile: 1, uploadFile: 1, httpGet: 1, httpPost: 1, invoke: 1
  };
  function isCallbackStyle(path, fn, argc) {
    if (fn.length > argc) return true;
    var parts = path.split(".");
    var name = parts[parts.length - 1];
    if (parts.length === 1 && callbackStyle[name]) return true;
    return parts.length === 2 && parts[0] === "tg" && name !== "myId" && name !== "myDc";
  }
  // Вызов wg.* из Python/Lua/Ruby/Go (нативный мост → сюда).
  global.__wgLangCall = function (path, args, resolve, reject) {
    var settled = false;
    function done(value) { if (!settled) { settled = true; resolve(safe(value)); } }
    function fail(error) { if (!settled) { settled = true; reject(String(error && error.message ? error.message : error)); } }
    try {
      path = String(path);
      var parts = path.split(".");
      var owner = wg;
      for (var i = 0; i < parts.length - 1; i++) owner = owner ? owner[parts[i]] : undefined;
      var fn = owner ? owner[parts[parts.length - 1]] : undefined;
      if (!isFn(fn)) { fail("wg." + path + " — нет такой функции"); return; }
      args = Array.isArray(args) ? args.slice() : [];
      var viaCallback = isCallbackStyle(path, fn, args.length);
      if (viaCallback) {
        args.push(function () { done(arguments.length > 1 ? Array.prototype.slice.call(arguments) : arguments[0]); });
      }
      var result = fn.apply(owner, args);
      if (result && isFn(result.then)) result.then(done, fail);
      else if (!viaCallback) done(result);
    } catch (e) {
      fail(e);
    }
  };
  // stdout/stderr/события из других языков.
  global.__wgLangEvent = function (lang, kind, data) {
    var map = langEvents[lang] || {};
    function each(list, args) {
      (list || []).forEach(function (handler) {
        try { handler.apply(null, args); } catch (e) { console.error(e); }
      });
    }
    if (kind === "event" && data && typeof data === "object") {
      each(map[data.event], [data.data]);
      each(map["*"], [data.event, data.data]);
    } else {
      each(map[kind], [data]);
    }
  };
})(this);