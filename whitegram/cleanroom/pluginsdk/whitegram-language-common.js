"use strict";
var WG = { pluginId: "", lang: "", ready: null };
var RT_BASE = "wgrt://app/rt/";
var handlers = {};

function wgSyncGet(url) {
  var xhr = new XMLHttpRequest();
  xhr.open("GET", url, false);
  xhr.send(null);
  if (xhr.status !== 200) throw new Error("Не удалось загрузить " + url + " (" + xhr.status + ")");
  return xhr.responseText;
}

// Синхронный вызов нативного моста. Блокирует ТОЛЬКО этот воркер.
function wgBridgeRaw(op, body) {
  var xhr = new XMLHttpRequest();
  xhr.open("POST", "wgrt://app/bridge/" + op + "?p=" + encodeURIComponent(WG.pluginId) + "&l=" + encodeURIComponent(WG.lang), false);
  xhr.setRequestHeader("Content-Type", "application/json");
  if (body.length < 3000) {
    xhr.setRequestHeader("X-WG-Payload", btoa(unescape(encodeURIComponent(body))));
  }
  xhr.send(body);
  if (xhr.status !== 200) throw new Error("bridge " + op + ": HTTP " + xhr.status);
  return xhr.responseText;
}
function wgBridge(op, payload) {
  var response = JSON.parse(wgBridgeRaw(op, JSON.stringify(payload || {})));
  if (!response.ok) {
    var error = new Error(response.error || "bridge error");
    error.timeout = !!response.timeout;
    throw error;
  }
  return response.result;
}
// Для языков, которым удобнее строки: JSON туда, JSON обратно (ошибка — исключение).
function wgBridgeJSON(op, json) { return JSON.stringify({ r: wgBridge(op, JSON.parse(json)) }); }
function wgCall(path, args) { return wgBridge("wg", { path: String(path), args: args || [] }); }
function wgCallJSON(path, argsJSON) { return JSON.stringify({ r: wgCall(path, JSON.parse(argsJSON || "[]")) }); }
function wgEvent(kind, data) { postMessage({ type: "event", kind: kind, data: data }); }
function wgPackageFiles() { return wgBridge("pkg.list", {}); }
function wgPackageManifest() { return wgBridge("pkg.manifest", {}); }
function wgReadPackageFile(path) { return wgSyncGet("wgrt://app/pkg/" + encodeURIComponent(WG.pluginId) + "/" + path); }
function wgRuntimeConfig() { return JSON.parse(wgSyncGet(RT_BASE + WG.lang + "/runtime.json")); }
function wgSafe(value) {
  if (value === undefined) return null;
  try { return JSON.parse(JSON.stringify(value)); } catch (e) { return String(value); }
}

// Всё, что интерпретатор печатает мимо своих потоков вывода, тоже попадает в журнал.
console.log = function () { wgEvent("stdout", Array.prototype.join.call(arguments, " ")); };
console.info = console.log;
console.warn = function () { wgEvent("stderr", Array.prototype.join.call(arguments, " ")); };
console.error = console.warn;

self.onmessage = function (event) {
  var m = event.data || {};
  if (m.type === "init") {
    WG.pluginId = m.pluginId;
    WG.lang = m.lang;
    WG.ready = Promise.resolve().then(function () { return self.wgInit(); });
    WG.ready.catch(function (e) { wgEvent("stderr", "Не удалось запустить " + WG.lang + ": " + (e && e.message ? e.message : e)); });
    return;
  }
  if (m.type === "op") {
    WG.ready.then(function () {
      var handler = handlers[m.op];
      if (!handler) throw new Error("Операция не поддерживается языком " + WG.lang + ": " + m.op);
      return handler(m.payload || {});
    }).then(function (result) {
      postMessage({ type: "result", id: m.id, ok: true, result: wgSafe(result) });
    }, function (error) {
      postMessage({ type: "result", id: m.id, ok: false, error: String(error && error.message ? error.message : error) });
    });
  }
};