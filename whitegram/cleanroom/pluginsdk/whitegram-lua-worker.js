importScripts("common.js");
var lua = null;

self.wgInit = async function () {
  var config = wgRuntimeConfig();
  var base = RT_BASE + "lua/";
  importScripts(base + (config.entry || "wasmoon.js"));
  var factory = new self[config.global || "wasmoon"].LuaFactory(base + (config.wasm || "glue.wasm"));
  var files = wgPackageFiles().filter(function (path) { return /\.lua$/i.test(path); });
  for (var i = 0; i < files.length; i++) {
    await factory.mountFile("/plugin/" + files[i], wgReadPackageFile(files[i]));
  }
  lua = await factory.createEngine({ injectObjects: true });
  lua.global.set("__wg_call", function (path, args) {
    return wgCall(path, Array.isArray(args) ? args : (args ? Object.keys(args).sort(function (a, b) { return a - b; }).map(function (k) { return args[k]; }) : []));
  });
  lua.global.set("__wg_bridge", function (op, payload) { return wgBridge(op, payload || {}); });
  lua.global.set("print", function () { wgEvent("stdout", Array.prototype.map.call(arguments, String).join("\t")); });
  await lua.doString([
    "package.path = '/plugin/?.lua;/plugin/?/init.lua;' .. package.path",
    "local function ns(prefix)",
    "  return setmetatable({}, {",
    "    __index = function(_, key) return ns(prefix == '' and key or (prefix .. '.' .. key)) end,",
    "    __call = function(_, ...) return __wg_call(prefix, {...}) end",
    "  })",
    "end",
    "wg = ns('')",
    "-- Прямой вызов других языков плагина: lang.go.call('Hello', 'Макс'), lang.python.call('tools.check', host),",
    "-- lang.ruby.run('[1,2].sum'), lang.go.Hello('Макс').",
    "lang = setmetatable({}, { __index = function(_, name)",
    "  return setmetatable({",
    "    call = function(fn, ...) return __wg_call('lang.' .. name .. '.call', {fn, ...}) end,",
    "    run = function(code) return __wg_call('lang.' .. name .. '.run', {code}) end,",
    "    load = function(path) return __wg_call('lang.' .. name .. '.import', {path}) end",
    "  }, { __index = function(_, fn) return function(...) return __wg_call('lang.' .. name .. '.call', {fn, ...}) end end })",
    "end })",
    "-- Сокеты в духе LuaSocket: socket.tcp():connect(host, port), :send, :receive, :close.",
    "-- TLS: s:tls('example.com') ДО connect.",
    "socket = {}",
    "function socket.sleep(sec) __wg_bridge('sleep', {ms = sec * 1000}) end",
    "function socket.tcp()",
    "  local s = { timeout = nil }",
    "  function s:settimeout(t) self.timeout = t end",
    "  function s:tls(server) self.tlsName = server or true end",
    "  function s:connect(host, port)",
    "    local serverName = type(self.tlsName) == 'string' and self.tlsName or host",
    "    local r = __wg_bridge('sock.open', {host = host, port = port, proto = 'tcp', tls = self.tlsName ~= nil, serverName = serverName, timeout = self.timeout or 15})",
    "    self.id = r.id",
    "    return 1",
    "  end",
    "  function s:send(data) return __wg_bridge('sock.sendText', {id = self.id, text = data}) end",
    "  function s:receive(n) local r = __wg_bridge('sock.recvText', {id = self.id, max = type(n) == 'number' and n or 65536, timeout = self.timeout}); if r.eof and r.text == '' then return nil, 'closed' end; return r.text end",
    "  function s:close() __wg_bridge('sock.close', {id = self.id}) end",
    "  return s",
    "end"
  ].join("\n"));
};

// Текстовые обёртки для Lua: base64 там неудобен.
var nativeBridge = wgBridge;
wgBridge = function (op, payload) {
  if (op === "sock.sendText") {
    var bytes = unescape(encodeURIComponent(String(payload.text || "")));
    return nativeBridge("sock.send", { id: payload.id, b64: btoa(bytes) });
  }
  if (op === "sock.recvText") {
    var r = nativeBridge("sock.recv", { id: payload.id, max: payload.max, timeout: payload.timeout });
    var raw = r.b64 ? atob(r.b64) : "";
    var text;
    try { text = decodeURIComponent(escape(raw)); } catch (e) { text = raw; }
    return { text: text, eof: !!r.eof };
  }
  return nativeBridge(op, payload);
};

handlers.run = async function (p) { return await lua.doString(String(p.code || "")); };
handlers.eval = handlers.run;
handlers.call = async function (p) {
  lua.global.set("__wg_args", p.args || []);
  return await lua.doString("return " + String(p.fn) + "(table.unpack(__wg_args))");
};
handlers.import = async function (p) {
  var name = String(p.module || p.path || "").replace(/\.lua$/, "").replace(/\//g, ".");
  await lua.doString("_G[" + JSON.stringify(name.split(".").pop()) + "] = require(" + JSON.stringify(name) + ")");
  return true;
};
handlers.install = async function () { return []; };