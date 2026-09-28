"use strict";

const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const cleanroom = path.resolve(__dirname, "../../cleanroom");
const sdkDirectory = path.join(cleanroom, "pluginsdk");
const runtimeSource = fs.readFileSync(path.join(cleanroom, "WhitegramPluginRuntime.swift"), "utf8");
const resourceDeclaration = /static let resources = \[([^\]]+)\]/.exec(runtimeSource);
if (!resourceDeclaration) throw new Error("Native resource declaration is missing");
const resources = [...resourceDeclaration[1].matchAll(/"([^"]+)"/g)].map(match => match[1] + ".js");

// Consume the actual native registry declarations, not a separately maintained
// list of invented native methods. All returned Telegram/UI data below is a
// fixture: these tests exercise the real recovered JS against its host contract.
function manifestFromSwift() {
  const manifest = [];
  for (const match of runtimeSource.matchAll(/\badd\(\[([\s\S]*?)\]([^)]*)\)/g)) {
    const names = [...match[1].matchAll(/"([^"]+)"/g)].map(value => value[1]);
    const permission = /permission: "([^"]+)"/.exec(match[2])?.[1] || "";
    const sync = !/sync: false/.test(match[2]);
    const exposed = !/exposed: false/.test(match[2]);
    for (const name of names) manifest.push({ path: name, permission, sync, exposed });
  }
  if (manifest.length < 50) throw new Error("Native registry extraction failed");
  return manifest;
}

function fail(code, message) { throw Object.assign(new Error(message), { code }); }
function contained(name, allowEmpty = false) {
  if (allowEmpty && name === "") return "";
  if (typeof name !== "string" || !name || name.startsWith("/") || /[\\:\x00-\x1f\x7f]/.test(name)) fail("INVALID_PATH", "Expected a relative path");
  if (name.split("/").some(part => !part || part === "." || part === "..")) fail("INVALID_PATH", "Invalid path component");
  return name;
}

class NativeHostFixture {
  constructor(options = {}) {
    this.manifest = manifestFromSwift();
    this.descriptors = new Map(this.manifest.map(entry => [entry.path, entry]));
    this.grants = { storage: true, uiMutation: true, ...(options.grants || {}) };
    this.state = "starting";
    this.active = true;
    this.unloading = false;
    this.calls = [];
    this.logs = [];
    this.pending = new Map();
    this.timers = new Map();
    this.surfaces = new Map();
    this.toasts = [];
    this.package = new Map(Object.entries(options.files || { "main.js": "" }));
    this.data = options.data || new Map();
    this.storage = options.storage || Object.create(null);
    this.preferences = Object.create(null);
    this.surfaceSequence = 0;
    this.loadedResources = [];
    this.context = vm.createContext({
      __wgHostSync: (name, json) => this.hostSync(name, json),
      __wgHostAsync: (name, json, token) => this.hostAsync(name, json, token)
    });
    for (const file of resources.slice(0, 4)) this.load(file);
    this.run("__wgInstallNativeCompatibility()");
    this.load("whitegram-sdk-bridge.js");
  }

  load(file) {
    if (!resources.includes(file)) throw new Error("Resource is outside the runtime allowlist");
    this.loadedResources.push(file);
    this.run(fs.readFileSync(path.join(sdkDirectory, file), "utf8"), file);
  }
  run(source, filename = "test-plugin.js") { return vm.runInContext(source, this.context, { filename, timeout: 2000 }); }
  async flush() { await new Promise(resolve => setImmediate(resolve)); }
  async entry(source) { this.run(source); this.run("__wgFinishEntry()"); await this.flush(); }

  validate(name, synchronous) {
    if (!this.active && !(this.unloading && (name === "log" || name === "permissions.check" || name.startsWith("storage.")))) fail("PLUGIN_STOPPED", "Plugin is stopped");
    const descriptor = this.descriptors.get(name);
    if (!descriptor || descriptor.sync !== synchronous) fail("UNSUPPORTED_API", name);
    if (descriptor.permission && !this.grants[descriptor.permission]) fail("PERMISSION_DENIED", descriptor.permission);
    if (name === "tg.sendFileMessage" && (!this.grants.messages || !this.grants.storage)) fail("PERMISSION_DENIED", "messages and storage");
    if (name === "tg.openChat" && !this.grants.uiMutation) fail("PERMISSION_DENIED", "uiMutation");
  }

  hostSync(name, json) {
    try {
      this.validate(name, true);
      const args = JSON.parse(json);
      this.calls.push({ name, args });
      return JSON.stringify({ ok: true, value: this.sync(name, args) ?? null });
    } catch (error) {
      return JSON.stringify({ ok: false, error: { code: error.code || "NATIVE_ERROR", message: error.message } });
    }
  }

  sync(name, args) {
    switch (name) {
      case "runtime.info": return { id: "fixture-plugin", name: "Fixture", version: "1.0", entry: "main.js", manifest: this.manifest };
      case "runtime.started": this.state = "running"; return true;
      case "runtime.failed": this.state = "failed"; this.logs.push({ level: "error", text: args[0] }); return null;
      case "permissions.check": return this.grants[args[0]] === true;
      case "tg.myId": return "123";
      case "capabilities.info": return { ios: "17.0", functions: this.manifest.filter(entry => entry.exposed).map(entry => entry.path), subsystems: { javascript: "1", ui: "1", tg: "12.9.2" }, features: { http: true, peerWatches: true, globalTelegramHooks: false, languageWorkers: false } };
      case "log": this.logs.push({ level: args[0], text: args[1] }); return null;
      case "timer.create": this.timers.set(args[0], { delay: args[1], repeats: args[2] }); return args[0];
      case "timer.clear": this.timers.delete(args[0]); return null;
      case "storage.get": return this.storage[args[0]] ?? args[1] ?? null;
      case "storage.set": this.storage[args[0]] = args[1]; return true;
      case "storage.remove": delete this.storage[args[0]]; return true;
      case "storage.keys": return Object.keys(this.storage);
      case "storage.clear": for (const key of Object.keys(this.storage)) delete this.storage[key]; return true;
      case "package.list": return [...this.package.keys()];
      case "package.read": {
        const key = contained(args[0]);
        const value = this.package.get(key);
        return value == null ? null : args[1] ? Buffer.from(value).toString("base64") : value;
      }
      case "package.resolveModule": return this.resolveModule(args[0], args[1]);
      case "ui.createSurface": {
        if (!["window", "sheet", "screen"].includes(args[0])) fail("UNSUPPORTED_UI", args[0]);
        this.validateTree(args[2]);
        if (this.surfaces.size >= 8) fail("QUOTA_EXCEEDED", "Surfaces");
        const id = "surface" + (++this.surfaceSequence);
        this.surfaces.set(id, { kind: args[0], options: args[1], tree: args[2], visible: args[0] !== "screen" });
        return id;
      }
      case "ui.updateSurface": this.validateTree(args[1]); this.surface(args[0]).tree = args[1]; return true;
      case "ui.setSurfaceOptions": Object.assign(this.surface(args[0]).options, args[1]); return true;
      case "ui.pushScreen": this.surface(args[0]).visible = true; return true;
      case "ui.setSurfaceVisible": this.surface(args[0]).visible = args[1]; return true;
      case "ui.surfaceInfo": return this.surface(args[0]);
      case "ui.closeSurface": {
        this.surface(args[0]);
        this.surfaces.delete(args[0]);
        queueMicrotask(() => this.context.__wgUIDispatch(args[0], "__closed", null));
        return true;
      }
      case "ui.toast": if (this.toasts.length >= 4) fail("QUOTA_EXCEEDED", "Toasts"); this.toasts.push({ text: args[0], options: args[1] }); return null;
      case "ui.theme": return { dark: false, accent: "#007AFF" };
      case "ui.keyboardHeight": return 0;
      case "ui.haptic": return null;
      case "tg.unwatchMessages": return true;
      case "clipboard.get": return this.clipboard || null;
      case "clipboard.set": this.clipboard = args[0]; return true;
      default:
        if (name.startsWith("fs.")) return this.file(name.slice(3), args);
        if (name.startsWith("preferences.")) {
          if (String(args[0]).startsWith("pluginRuntime.")) fail("PERMISSION_DENIED", "Runtime permission records are private");
          if (name.endsWith("values")) return Object.fromEntries(Object.entries(this.preferences).filter(([key]) => !key.startsWith("pluginRuntime.")));
          if (name.endsWith("get")) return this.preferences[args[0]] ?? args[1] ?? null;
          this.preferences[args[0]] = args[1]; return true;
        }
        fail("UNSUPPORTED_API", name);
    }
  }

  resolveModule(directory, name) {
    contained(directory, true);
    if (name.startsWith("/") || /[\\:\x00-\x1f]/.test(name)) fail("INVALID_PATH", name);
    const parts = directory ? directory.split("/") : [];
    for (const part of name.split("/")) {
      if (part === ".") continue;
      if (part === "..") { if (!parts.length) fail("INVALID_PATH", "Module escapes package"); parts.pop(); }
      else { contained(part); parts.push(part); }
    }
    const key = parts.join("/");
    for (const candidate of [key, key + ".js", key + ".json", key + "/index.js", key + "/index.json"]) {
      if (!this.package.has(candidate)) continue;
      const kind = path.posix.extname(candidate).slice(1);
      if (!["js", "json"].includes(kind)) fail("UNSUPPORTED_LANGUAGE", kind);
      return { path: candidate, dir: candidate.split("/").slice(0, -1).join("/"), kind, source: this.package.get(candidate) };
    }
    fail("MODULE_NOT_FOUND", name);
  }

  file(operation, args) {
    if (operation === "list") return [...this.data.keys()].filter(key => !args[0] || key.startsWith(contained(args[0]) + "/"));
    const key = contained(args[0]);
    if (operation === "exists") return this.data.has(key);
    if (operation === "remove") return this.data.delete(key);
    if (operation.startsWith("write")) {
      const bytes = operation === "write" ? Buffer.from(args[1]) : Buffer.from(operation === "writeBytes" ? args[1].__wgBase64 : args[1], "base64");
      if (bytes.length > 2 * 1024 * 1024) fail("QUOTA_EXCEEDED", "File too large");
      this.data.set(key, bytes); return true;
    }
    const bytes = this.data.get(key);
    if (!bytes) return null;
    if (operation === "readBytes") return { __wgBase64: bytes.toString("base64") };
    return operation === "readBase64" ? bytes.toString("base64") : bytes.toString("utf8");
  }

  validateTree(tree) {
    if (tree == null) return;
    if (["web", "zstack", "imaginary"].includes(tree.type)) fail("UNSUPPORTED_UI", tree.type);
    for (const child of tree.children || []) this.validateTree(child);
  }
  surface(id) { if (!this.surfaces.has(id)) fail("SURFACE_NOT_FOUND", id); return this.surfaces.get(id); }

  hostAsync(name, json, token) {
    const args = JSON.parse(json);
    this.calls.push({ name, args, token });
    try { this.validate(name, false); this.pending.set(token, { name, args }); }
    catch (error) { queueMicrotask(() => this.context.__wgNativeComplete(token, { ok: false, error: { code: error.code, message: error.message } })); }
  }
  nextRequest(name) {
    const entry = [...this.pending].find(([, request]) => request.name === name);
    if (!entry) throw new Error("No pending " + name);
    return { token: entry[0], ...entry[1] };
  }
  settle(name, value, error) {
    const request = this.nextRequest(name);
    this.pending.delete(request.token);
    this.context.__wgNativeComplete(request.token, error ? { ok: false, error } : { ok: true, value });
  }
  fire(id) {
    const timer = this.timers.get(id);
    if (!timer || !this.active) return;
    if (!timer.repeats) this.timers.delete(id);
    this.context.__wgTimerFire(id);
  }
  finishToast(index = 0, dismissed = false) {
    const [toast] = this.toasts.splice(index, 1);
    if (toast?.options.actionCallback) this.context.__wgUIDispatch("__toast", toast.options.actionCallback, { dismissed });
  }
  async stop() {
    this.active = false;
    this.unloading = true;
    this.pending.clear(); this.timers.clear(); this.surfaces.clear(); this.toasts = [];
    this.run("__wgPrepareStop()");
    this.load("whitegram-plugin-host.js");
    this.run("__wgDidStop()");
    this.unloading = false;
    this.state = "stopped";
    await this.flush();
  }
}

module.exports = { NativeHostFixture, resources, sdkDirectory };
