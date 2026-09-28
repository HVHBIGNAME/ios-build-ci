"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { NativeHostFixture: Host, resources, sdkDirectory } = require("./native-host-fixture.cjs");

const code = expected => error => error && error.code === expected;
const plain = value => JSON.parse(JSON.stringify(value));

test("load order uses intact SDKs, never the truncated hooks HTML", async () => {
  assert.deepEqual(resources, ["whitegram-native-bootstrap.js", "whitegram-sdk-core.js", "whitegram-plugin-lifecycle.js", "whitegram-sdk-extensions.js", "whitegram-sdk-bridge.js", "whitegram-plugin-host.js"]);
  const host = new Host();
  assert.deepEqual(host.loadedResources, resources.slice(0, 5));
  assert.equal(host.run("wg.__sdkReady"), true);
  assert.equal(host.run("typeof __wgHostSync"), "undefined");
  assert.equal(host.run("typeof __wgHostAsync"), "undefined");
  assert.throws(() => new vm.Script(fs.readFileSync(path.join(sdkDirectory, "whitegram-sdk-hooks.js"), "utf8")), SyntaxError);
  await host.entry("console.log('started', {answer: 42})");
  assert.equal(host.state, "running");
  assert.ok(host.logs.some(entry => entry.text.includes('"answer":42')));
  await host.stop();
});

test("lifecycle registers an exported plugin exactly once and persists synchronous unload", async () => {
  const host = new Host();
  await host.entry(`
    module.exports = { onLoad: function(meta) { wg.storage.set('loads', (wg.storage.get('loads') || 0) + 1); },
      onUnload: function() { wg.storage.set('unloads', (wg.storage.get('unloads') || 0) + 1); } };
    wg.registerPlugin(module.exports);
  `);
  assert.equal(host.storage.loads, 1);
  assert.equal(host.run("wg.__pluginInstances.length"), 1);
  await host.stop();
  assert.equal(host.storage.unloads, 1);
  assert.equal(host.run("wg.__pluginInstances.length"), 0);
});

test("async onLoad waits for actual completion; rejection fails startup", async () => {
  const good = new Host({ grants: { account: true } });
  await good.entry("module.exports = { onLoad: async function() { this.me = await wg.getMe(); } };");
  assert.equal(good.state, "starting");
  good.settle("tg.getMe", { id: "123", title: "Fixture User" });
  await good.flush();
  assert.equal(good.state, "running");
  await good.stop();
  const bad = new Host();
  await bad.entry("module.exports = { onLoad: async function() { throw new Error('load failed'); } };");
  assert.equal(bad.state, "failed");
  assert.ok(bad.logs.some(entry => entry.text.includes("load failed")));
  await bad.stop();
});

test("timers pass arguments, reject string callbacks, catch exceptions and clean up", async () => {
  const host = new Host();
  host.run("var ticks = 0; var once = setTimeout(function(a,b) { ticks += a+b; }, 1, 2, 3); var repeat = setInterval(function(){ ticks++; }, 0);");
  const once = host.run("once"), repeat = host.run("repeat");
  assert.equal(host.timers.get(repeat).delay, 16);
  host.fire(once); host.fire(once); host.fire(repeat);
  assert.equal(host.run("ticks"), 6);
  assert.equal(host.timers.has(once), false);
  assert.throws(() => host.run("wg.setTimeout('eval code', 0)"), code("INVALID_ARGUMENT"));
  assert.throws(() => host.run("setTimeout('eval code', 0)"), code("INVALID_ARGUMENT"));
  const throwing = host.run("setTimeout(function(){ throw new Error('timer failed'); }, 0)");
  host.fire(throwing);
  assert.ok(host.logs.some(entry => entry.text.includes("timer failed")));
  await host.stop();
  host.fire(repeat);
  assert.equal(host.run("ticks"), 6);
  assert.equal(host.timers.size, 0);
  assert.throws(() => host.run("setTimeout(function(){}, 0)"), code("PLUGIN_STOPPED"));
});

test("timer limit and released slots bound callbacks", async () => {
  const host = new Host();
  host.run("var ids = []; for(var i=0;i<256;i++) ids.push(setInterval(function(){},1000));");
  assert.throws(() => host.run("setTimeout(function(){},0)"), code("QUOTA_EXCEEDED"));
  host.run("clearInterval(ids.pop()); setTimeout(function(){},0)");
  assert.equal(host.timers.size, 256);
  await host.stop();
});

test("stop rejects pending requests and sleeps; late callbacks cannot reenter", async () => {
  const host = new Host({ grants: { network: true } });
  const request = host.run("wg.request({url:'https://example.test'})");
  const token = host.nextRequest("http.request").token;
  const sleep = host.run("wg.sleep(10000)");
  const requestCheck = assert.rejects(request, code("PLUGIN_STOPPED"));
  const sleepCheck = assert.rejects(sleep, code("PLUGIN_STOPPED"));
  await host.stop();
  host.context.__wgNativeComplete(token, { ok: true, value: { status: 200 } });
  await Promise.all([requestCheck, sleepCheck]);
  assert.equal(host.pending.size, 0);
  assert.throws(() => host.run("wg.request({url:'https://example.test'})"), code("PLUGIN_STOPPED"));
});

test("permissions cover aliases, direct SDK calls, native calls, and revocation", async () => {
  const host = new Host();
  assert.throws(() => host.run("wg.getMe()"), /account/);
  assert.throws(() => host.run("wg.fetch('https://example.test')"), /network/);
  assert.throws(() => host.run("wg.__native.registerTab('screen',{})"), code("UNSUPPORTED_API"));
  // uiMutation is granted above; disabling it must also block direct native calls.
  host.grants.uiMutation = false;
  assert.throws(() => host.run("wg.__native.createSurface('sheet',{},null)"), code("PERMISSION_DENIED"));
  const direct = host.run("new Promise(function(resolve,reject){ wg.__sdk.call('tg.getMe',[],resolve,reject); })");
  await assert.rejects(direct, code("PERMISSION_DENIED"));
  host.grants.network = true;
  const request = host.run("wg.request({url:'https://example.test'})");
  host.settle("http.request", { ok: true, status: 204, body: "", headers: {} });
  await request;
  host.grants.network = false;
  host.run("__wgPermissionGate = function(){return true};");
  assert.throws(() => host.run("wg.fetch('https://example.test')"), /network/);
  await host.stop();
});

test("HTTP request, legacy fetch, JSON errors, and status stay truthful", async () => {
  const host = new Host({ grants: { network: true } });
  const response = host.run("var callbackStatus; wg.httpGet('https://example.test/missing', function(r){callbackStatus=r.status;})");
  host.settle("http.request", { ok: false, status: 404, url: "https://example.test/missing", body: "missing", headers: {}, base64: "bWlzc2luZw==", elapsedMs: 4 });
  assert.equal((await response).status, 404);
  await host.flush();
  assert.equal(host.run("callbackStatus"), 404);
  const text = host.run("var fetchError, fetchBody; wg.fetch('https://example.test',function(e,b){fetchError=e;fetchBody=b;})");
  host.settle("http.request", { ok: true, status: 201, body: "created" });
  assert.equal(await text, "created");
  await host.flush();
  assert.equal(host.run("fetchBody"), "created");
  assert.equal(host.run("fetchError"), null);
  const missing = host.run("wg.fetch('https://example.test')");
  host.settle("http.request", { ok: false, status: 403, body: "forbidden" });
  await assert.rejects(missing, code("HTTP_STATUS"));
  const invalidJSON = host.run("wg.fetchJSON('https://example.test')");
  host.settle("http.request", { ok: true, status: 200, body: "<html>" });
  await assert.rejects(invalidJSON, /JSON|Unexpected token/);
  const offline = host.run("wg.request({url:'https://example.test'})");
  host.settle("http.request", null, { code: "HTTP_ERROR", message: "offline" });
  await assert.rejects(offline, code("HTTP_ERROR"));
  const oldOffline = host.run("var oldError; wg.httpGet('https://example.test',function(response){oldError=response;})");
  host.settle("http.request", null, { code: "HTTP_ERROR", message: "offline" });
  await assert.rejects(oldOffline, code("HTTP_ERROR"));
  await host.flush();
  assert.equal(host.run("oldError.ok"), false);
  assert.equal(host.run("oldError.status"), 0);
  assert.equal(host.run("oldError.error.code"), "HTTP_ERROR");
  await host.stop();
});

test("legacy reply retains message id and invoke waits for edit errors", async () => {
  const host = new Host({ grants: { messages: true } });
  const reply = host.run("wg.reply('channel:99',45,'reply body')");
  assert.deepEqual(host.nextRequest("tg.reply").args, ["channel:99", 45, "reply body"]);
  host.settle("tg.reply", { queued: true, messageIds: [{ id: 1, namespace: 1, peerId: "99" }] });
  assert.equal((await reply).queued, true);
  const edit = host.run("var editCallback; wg.invoke('client.editMessage',{peerId:'123',messageId:3,text:'edit'},function(value){editCallback=value;})");
  assert.equal(host.run("editCallback"), undefined);
  host.settle("tg.editMessage", null, { code: "TELEGRAM_ERROR", message: "restricted" });
  await assert.rejects(edit, code("TELEGRAM_ERROR"));
  await host.flush();
  assert.equal(host.run("editCallback.ok"), false);
  await assert.rejects(host.run("wg.invoke('client.fake',{})"), code("UNSUPPORTED_API"));
  await host.stop();
});

test("scoped JSON and files persist across plugin sessions; bytes roundtrip", async () => {
  const storage = Object.create(null), data = new Map();
  const host = new Host({ storage, data });
  host.run("wg.storage.set('settings',{enabled:true,list:[1,2]}); wg.fs.write('notes/message.txt','hello'); var b=new Uint8Array([0,1,127,128,255]); wg.fs.writeBytes('data.bin',b.subarray(1,4));");
  assert.deepEqual(Array.from(host.run("wg.fs.readBytes('data.bin')")), [1, 127, 128]);
  await host.stop();
  const next = new Host({ storage, data });
  assert.deepEqual(plain(next.run("wg.storage.get('settings')")), { enabled: true, list: [1, 2] });
  assert.equal(next.run("wg.fs.read('notes/message.txt')"), "hello");
  assert.equal(next.run("wg.fs.remove('absent.txt')"), false);
  assert.deepEqual(plain(next.run("wg.fs.list('notes')")), ["notes/message.txt"]);
  const unrelated = new Host();
  assert.equal(unrelated.run("wg.storage.get('settings')"), null);
  await next.stop(); await unrelated.stop();
});

test("package modules use canonical relative paths, caching, cycles and failure eviction", async () => {
  const host = new Host({ files: {
    "main.js": "", "lib/a.js": "exports.n=1; exports.b=require('./b').n;", "lib/b.js": "exports.n=require('./a').n+1;",
    "data.json": '{"answer":42}', "bad.js": "globalThis.attempts=(globalThis.attempts||0)+1; throw Error('broken module');",
    "bad.json": "[invalid", "helper.py": "print('not run')"
  } });
  assert.deepEqual(plain(host.run("require('./lib/a')")), { n: 1, b: 2 });
  assert.equal(host.run("require('./lib/../data.json').answer"), 42);
  assert.equal(host.run("require('whitegram') === wg"), true);
  assert.throws(() => host.run("require('./bad')"), /broken module/);
  assert.throws(() => host.run("require('./bad.js')"), /broken module/);
  assert.equal(host.run("attempts"), 2);
  assert.throws(() => host.run("require('./bad.json')"), /JSON|Unexpected token/);
  host.package.set("bad.json", '{"fixed":true}');
  assert.equal(host.run("require('./bad.json').fixed"), true);
  assert.throws(() => host.run("require('./helper.py')"), code("UNSUPPORTED_LANGUAGE"));
  assert.throws(() => host.run("require('node:fs')"), code("INVALID_PATH"));
  await host.stop();
});

test("path errors cross the real JS bridge; it cannot reach absolute or parent files", async () => {
  const host = new Host();
  for (const value of ["../secret", "/etc/passwd", "C:\\secret", "file:///secret", "a/../../b", "a//b", "a/./b", "a\0b"]) {
    assert.throws(() => host.run(`wg.fs.write(${JSON.stringify(value)},'no')`), code("INVALID_PATH"));
    assert.throws(() => host.run(`wg.files.read(${JSON.stringify(value)})`), code("INVALID_PATH"));
  }
  assert.throws(() => host.run("require('../outside')"), code("INVALID_PATH"));
  assert.equal(host.data.size, 0);
  await host.stop();
});

test("CommonJS cycles back to the entry do not evaluate it twice", async () => {
  const source = "globalThis.entryRuns=(globalThis.entryRuns||0)+1; exports.stage='before'; exports.child=require('./child'); exports.stage='after';";
  const host = new Host({ files: { "main.js": source, "child.js": "module.exports={parentStage:require('./main').stage};" } });
  await host.entry(source);
  assert.equal(host.run("entryRuns"), 1);
  assert.equal(host.run("module.exports.child.parentStage"), "before");
  assert.equal(host.run("module.loaded"), true);
  assert.equal(host.run("__filename"), "main.js");
  await host.stop();
});

test("native UI normalization, binding, stale callback invalidation and close are connected", async () => {
  const host = new Host();
  const id = host.run(`var changes=[],closes=0;
    var surface=wg.ui.sheet({title:'State', state:{enabled:false},onClose:function(){closes++;},
      render:function(state){return wg.ui.VStack([wg.ui.Toggle({title:'Enabled',bind:'enabled',onChange:function(v){changes.push(v);}}),wg.ui.Text(String(state.enabled))]);}}); surface.id;`);
  const callback = host.surface(id).tree.children[0].props.onChange.slice(5);
  assert.equal(typeof id, "string");
  host.context.__wgUIDispatch(id, callback, { value: true });
  assert.equal(host.run("surface.state.enabled"), true);
  assert.equal(host.surface(id).tree.children[1].props.text, "true");
  host.context.__wgUIDispatch(id, callback, { value: false });
  assert.equal(host.run("surface.state.enabled"), true);
  host.run("surface.close()");
  await host.flush();
  assert.equal(host.run("surface.isClosed"), true);
  assert.equal(host.run("closes"), 1);
  assert.throws(() => host.run("wg.ui.sheet({content:wg.ui.Web('<b>unsupported</b>')})"), code("UNSUPPORTED_UI"));
  assert.equal(host.surfaces.size, 0);
  await host.stop();
});

test("toast expiry frees callback without firing action; stop closes surface handles", async () => {
  const host = new Host();
  host.run("var actions=0; var handle=wg.ui.sheet({content:wg.ui.Text('Hi')});");
  for (let i = 0; i < 20; i++) {
    host.run("wg.ui.toast('text',{onAction:function(){actions++;}})");
    host.finishToast(0, true);
  }
  assert.equal(host.run("actions"), 0);
  host.run("wg.toast('text',{onAction:function(){actions++;}})");
  host.finishToast(0, false);
  assert.equal(host.run("actions"), 1);
  await host.stop();
  assert.equal(host.run("handle.isClosed"), true);
});

test("dialog cancellation and native errors settle Promise callers", async () => {
  const host = new Host();
  const confirmation = host.run("wg.ui.confirm('Title','Message')");
  host.settle("ui.confirm", false);
  assert.equal(await confirmation, false);
  const failure = host.run("wg.ui.confirm('Title','Message')");
  host.settle("ui.confirm", null, { code: "UI_BUSY", message: "Another dialog is open" });
  await assert.rejects(failure, code("UI_BUSY"));
  const menu = host.run("var cancelled=0; wg.ui.menu({items:['One'],onCancel:function(){cancelled++;}})");
  host.settle("ui.actionSheet", -1);
  assert.equal(await menu, -1);
  assert.equal(host.run("cancelled"), 1);
  await host.stop();
});

test("recovered events, wildcard matching, once, streams and state batching work", async () => {
  const host = new Host();
  host.run("var seen=[]; wg.events.once('plugin.*',function(p,n){seen.push([p.n,n]);}); wg.events.emit('plugin.test',{n:1},true);");
  host.fire([...host.timers.keys()][0]);
  host.run("wg.events.emit('plugin.test',{n:2})");
  host.fire([...host.timers.keys()][0]);
  assert.deepEqual(plain(host.run("seen")), [[1, "plugin.test"]]);
  assert.equal(host.run("wg.events.sticky('plugin.*')[0].payload.n"), 1);
  host.run("var stream=wg.events.stream('plugin.*')");
  assert.equal(host.run("stream[Symbol.asyncIterator]() === stream"), true);
  const next = host.run("stream.next()");
  host.run("wg.events.emit('plugin.stream',{n:3})");
  host.fire([...host.timers.keys()][0]);
  assert.equal((await next).value.name, "plugin.stream");
  const ended = host.run("stream.next()");
  host.run("var notifications=0; var store=wg.state({a:0,b:0}); store.watch(function(){notifications++;}); store.batch(function(){store.set('a',1);store.set('b',2);});");
  assert.equal(host.run("notifications"), 1);
  await host.stop();
  assert.equal((await ended).done, true);
});

test("unsupported hooks cannot masquerade as installed capabilities", async () => {
  const host = new Host();
  for (const api of ["tabs.add", "ui.overlay", "ui.provide", "intercept", "services.provide", "jobs.schedule", "tg.invoke", "postbox.transaction", "lang.python.run", "fakeAPI"]) {
    assert.equal(host.run(`wg.capabilities.has(${JSON.stringify(api)})`), false, api);
  }
  for (const source of ["wg.tabs.add({})", "wg.ui.overlay({})", "wg.ui.provide('slot',function(){})", "wg.intercept('tg',function(){})", "wg.services.provide('service',{})", "wg.fakeAPI()", "wg.__native.fakeAPI()", "wg.on('onMessageReceive',function(){})"]) {
    assert.throws(() => host.run(source), code("UNSUPPORTED_API"), source);
  }
  assert.equal(host.run("wg.lang.python.installed"), false);
  assert.deepEqual(plain(host.run("wg.lang.available()")), []);
  await assert.rejects(host.run("wg.lang.python.run('print(1)')"), /UNSUPPORTED_LANGUAGE/);
  await assert.rejects(host.run("wg.tg.invoke('messages.sendMessage',{})"), code("UNSUPPORTED_API"));
  assert.equal(host.run("wg.__sdk.callSync('runtime.started',[]).error.code"), "UNSUPPORTED_API");
  assert.equal(host.state, "starting");
  await host.stop();
});

test("watched messages deliver real host snapshots and close unsubscribes", async () => {
  const host = new Host({ grants: { messages: true } });
  const watch = host.run("var snapshots=[]; wg.chat.watchMessages('user:123',function(p){snapshots.push(p);},20)");
  const args = host.nextRequest("tg.watchMessages").args;
  assert.equal(args[0], "user:123"); assert.equal(args[2], 20);
  host.context.__wgNativeEvent("chat.messages." + args[1], { initial: true, messages: [{ id: 1, text: "fixture" }], scope: "local" });
  host.settle("tg.watchMessages", args[1]);
  const handle = await watch;
  assert.equal(host.run("snapshots.length"), 1);
  handle.close(); handle.close();
  host.context.__wgNativeEvent("chat.messages." + args[1], { messages: [] });
  assert.equal(host.run("snapshots.length"), 1);
  assert.equal(host.calls.filter(call => call.name === "tg.unwatchMessages").length, 1);
  await host.stop();
});

test("function-form surfaces render and rejected async UI callbacks reach the log", async () => {
  const host = new Host();
  const id = host.run("wg.ui.sheet(function(){return wg.ui.Button('Fail',async function(){throw new Error('async button failure');});}).id");
  const callback = host.surface(id).tree.props.onTap.slice(5);
  host.context.__wgUIDispatch(id, callback, { value: null });
  await host.flush();
  assert.ok(host.logs.some(entry => entry.text.includes("async button failure")));
  await host.stop();
});

test("duplicate event functions have independent ids and handler quotas release slots", async () => {
  const host = new Host();
  host.run("var count=0;function handler(){count++;}var first=wg.events.on('plugin.x',handler);var second=wg.events.on('plugin.x',handler);wg.events.off('plugin.x',first);");
  host.context.__wgNativeEvent("plugin.x", {});
  assert.equal(host.run("count"), 1);
  host.run("wg.events.off('plugin.x',handler)");
  host.context.__wgNativeEvent("plugin.x", {});
  assert.equal(host.run("count"), 1);
  host.run("var ids=[];for(var i=0;i<256;i++)ids.push(wg.events.on('plugin.x',handler));");
  assert.throws(() => host.run("wg.events.on('plugin.x',handler)"), code("QUOTA_EXCEEDED"));
  host.run("wg.events.off('plugin.x',ids.pop());wg.events.on('plugin.x',handler);");
  await host.stop();
});

test("shipped notes plugin saves its bound field and only sends on explicit tap", async () => {
  const host = new Host({ grants: { account: true, messages: true } });
  await host.entry(fs.readFileSync(path.join(__dirname, "example-notes.js"), "utf8"));
  assert.equal(host.state, "running");
  assert.equal(host.pending.size, 0);
  const id = [...host.surfaces.keys()][0];
  const noteChange = host.surface(id).tree.children[1].props.onChange.slice(5);
  host.context.__wgUIDispatch(id, noteChange, { value: "A plugin note" });
  const save = host.surface(id).tree.children[2].children[0].props.onTap.slice(5);
  host.context.__wgUIDispatch(id, save, { value: null });
  assert.equal(host.storage.note, "A plugin note");
  const send = host.surface(id).tree.children[2].children[1].props.onTap.slice(5);
  host.context.__wgUIDispatch(id, send, { value: null });
  await host.flush();
  host.settle("tg.getMe", { id: "123", title: "Saved Messages" });
  await host.flush();
  assert.deepEqual(host.nextRequest("tg.sendTextMessage").args, ["123", "A plugin note"]);
  host.settle("tg.sendTextMessage", { queued: true, messageIds: [{ peerId: "123", id: 5, namespace: 1 }] });
  await host.flush();
  assert.match(host.surface(id).tree.children[3].props.text, /Queued in Saved Messages/);
  await host.stop();
  assert.equal(host.storage.note, "A plugin note");
});

test("invoke accepts the recovered msgId alias and menu callbacks receive the item title", async () => {
  const host = new Host({ grants: { messages: true } });
  const edit = host.run("wg.invoke('client.editMessage',{peerId:'user:123',msgId:17,text:'fixed'})");
  assert.deepEqual(host.nextRequest("tg.editMessage").args, ["user:123", 17, "fixed"]);
  host.settle("tg.editMessage", { updated: true });
  await edit;
  const menu = host.run("var picked;wg.ui.menu({items:[{title:'First',onTap:function(){}}]},function(index,title){picked=[index,title];})");
  host.settle("ui.actionSheet", 0);
  await menu;
  assert.deepEqual(plain(host.run("picked")), [0, "First"]);
  await host.stop();
});

test("unsubscribing another event pattern during delivery does not break dispatch", async () => {
  const host = new Host();
  host.run(`
    var rootCalls=0,sdkCalls=0;
    wg.on('plugin.*',function(){wg.off('plugin.root');rootCalls++;});
    wg.on('plugin.root',function(){rootCalls++;});
    wg.events.on('plugin.*',function(){wg.events.off('plugin.sdk');sdkCalls++;});
    wg.events.on('plugin.sdk',function(){sdkCalls++;});
  `);
  assert.doesNotThrow(() => host.context.__wgNativeEvent("plugin.root", {}));
  assert.doesNotThrow(() => host.context.__wgNativeEvent("plugin.sdk", {}));
  const before = host.run("sdkCalls");
  host.context.__wgNativeEvent("plugin.sdk", {});
  assert.equal(host.run("sdkCalls"), before + 1);
  await host.stop();
});

test("failed SDK argument packing releases temporary byte tokens", async () => {
  const host = new Host({ grants: { network: true } });
  const failed = host.run("wg.http.request({url:'https://example.test',body:Array.from({length:33},function(){return new Uint8Array([1]);})})");
  await assert.rejects(failed, code("QUOTA_EXCEEDED"));
  host.run("wg.fs.writeBytes('after-error.bin',new Uint8Array([7,8,9]))");
  assert.deepEqual(Array.from(host.run("wg.fs.readBytes('after-error.bin')")), [7, 8, 9]);
  assert.equal(host.pending.size, 0);
  await host.stop();
});

test("byte revival errors reject registry promises instead of leaving them pending", async () => {
  const host = new Host({ grants: { network: true } });
  host.run("var revivalResult='pending';wg.http.request({url:'https://example.test'}).then(function(){revivalResult='resolved';},function(e){revivalResult=e.code;})");
  host.settle("http.request", { __wgBytes: 999999 });
  await host.flush();
  assert.equal(host.run("revivalResult"), "INVALID_ARGUMENT");
  await host.stop();
});

test("async callbacks supplied by surface.update and surface.set are observed", async () => {
  const host = new Host();
  const id = host.run("var changing=wg.ui.sheet({content:wg.ui.Text('initial')});changing.id");
  host.run("changing.update(wg.ui.Button('Updated',async function(){throw Error('updated callback rejection');}));changing.set({onClose:async function(){throw Error('close callback rejection');}})");
  const callback = host.surface(id).tree.props.onTap.slice(5);
  host.context.__wgUIDispatch(id, callback, { value: null });
  await host.flush();
  assert.ok(host.logs.some(entry => entry.text.includes("updated callback rejection")));
  host.run("changing.close()");
  await host.flush();
  assert.ok(host.logs.some(entry => entry.text.includes("close callback rejection")));
  await host.stop();
});

test("a rejected surface update releases the invalidated native controls", async () => {
  const host = new Host();
  host.run("var invalidated=wg.ui.sheet({content:wg.ui.Button('Old',function(){})});");
  assert.throws(() => host.run("invalidated.update(wg.ui.Web('unsupported'))"), code("UNSUPPORTED_UI"));
  await host.flush();
  assert.equal(host.surfaces.size, 0);
  assert.equal(host.run("invalidated.isClosed"), true);
  await host.stop();
});

test("frozen lifecycle objects are registered without modifying user methods", async () => {
  const host = new Host();
  await host.entry("module.exports=Object.freeze({onLoad:function(){wg.storage.set('frozenLoaded',true);},onUnload:function(){wg.storage.set('frozenUnloaded',true);}})");
  assert.equal(host.state, "running");
  assert.equal(host.storage.frozenLoaded, true);
  await host.stop();
  assert.equal(host.storage.frozenUnloaded, true);
});

test("startup awaits plugins registered by another asynchronous onLoad", async () => {
  const host = new Host({ grants: { account: true, messages: true } });
  await host.entry(`module.exports={onLoad:async function(){
    await wg.getMe();
    wg.registerPlugin({onLoad:async function(){await wg.getPeer('user:123');}});
  }};`);
  host.settle("tg.getMe", { id: "123" });
  await host.flush();
  assert.equal(host.state, "starting");
  host.settle("tg.getPeer", { id: "123" });
  await host.flush();
  assert.equal(host.state, "running");
  await host.stop();
});

test("private permission records are inaccessible through shared preferences", async () => {
  const host = new Host({ grants: { settings: true } });
  host.preferences["pluginRuntime.permissions.other"] = { messages: true };
  host.run("wg.preferences.set('sample.enabled',true)");
  assert.equal(host.run("wg.preferences.get('sample.enabled')"), true);
  assert.throws(() => host.run("wg.preferences.get('pluginRuntime.permissions.other')"), /PERMISSION_DENIED|private/);
  assert.throws(() => host.run("wg.preferences.set('pluginRuntime.permissions.other',{})"), /PERMISSION_DENIED|private/);
  assert.deepEqual(plain(host.run("wg.preferences.values()")), { "sample.enabled": true });
  await host.stop();
});

test("recovered Telegram client aliases and registry methods preserve native arguments", async () => {
  const host = new Host({ grants: { account: true, messages: true, media: true } });
  assert.equal(host.run("wg.tg.myId()"), "123");
  const cases = [
    ["wg.client.sendMessage('user:123','hello')", "tg.sendTextMessage", ["user:123", "hello"]],
    ["wg.client.sendFile('user:123','package:doc.txt',{caption:'doc',mimeType:'text/plain'})", "tg.sendFileMessage", ["user:123", "package:doc.txt", "doc", "text/plain"]],
    ["wg.client.sendDice('user:123','🎯')", "tg.sendDiceMessage", ["user:123", "🎯"]],
    ["wg.client.sendLocation('user:123',12.5,42.1)", "tg.sendLocationMessage", ["user:123", 12.5, 42.1]],
    ["wg.client.sendContact('user:123',{firstName:'A',lastName:'B',phoneNumber:'+123'})", "tg.sendContactMessage", ["user:123", "A", "B", "+123"]],
    ["wg.client.getMessages('user:123',10,50)", "tg.getMessages", ["user:123", 10, 50]],
    ["wg.tg.getMessage('user:123',45)", "tg.getMessage", ["user:123", 45]],
    ["wg.tg.reply('user:123',45,'answer')", "tg.reply", ["user:123", 45, "answer"]],
    ["wg.forwardMessage('user:123',45,'channel:99')", "tg.forwardMessage", ["user:123", 45, "channel:99"]],
    ["wg.deleteMessage('user:123',45,true)", "tg.deleteMessage", ["user:123", 45, true]],
    ["wg.pinMessage('user:123',45,false)", "tg.pinMessage", ["user:123", 45, false]],
    ["wg.reactToMessage('user:123',45,'👍')", "tg.reactToMessage", ["user:123", 45, "👍"]],
    ["wg.markChatAsRead('user:123')", "tg.markChatAsRead", ["user:123"]],
    ["wg.openChat('user:123')", "tg.openChat", ["user:123"]]
  ];
  for (const [source, method, args] of cases) {
    const result = host.run(source);
    assert.deepEqual(host.nextRequest(method).args, args, method);
    host.settle(method, { fixture: method });
    assert.equal((await result).fixture, method);
  }
  host.grants.storage = false;
  await assert.rejects(host.run("wg.tg.sendFileMessage('user:123','doc.txt')"), code("PERMISSION_DENIED"));
  host.grants.uiMutation = false;
  await assert.rejects(host.run("wg.tg.openChat('user:123')"), code("PERMISSION_DENIED"));
  await host.stop();
});

test("POST with an empty body stays POST and UI callbacks preserve legacy arity", async () => {
  const host = new Host({ grants: { network: true } });
  const post = host.run("wg.fetchPost('https://example.test',undefined)");
  assert.equal(host.nextRequest("http.request").args[0].method, "POST");
  host.settle("http.request", { ok: true, status: 204, body: "" });
  assert.equal(await post, "");
  const confirm = host.run("var confirmed;wg.ui.confirm('Title','Question',function(){confirmed=Array.from(arguments);})");
  host.settle("ui.confirm", true);
  await confirm;
  assert.deepEqual(plain(host.run("confirmed")), [true]);
  const prompt = host.run("wg.ui.prompt('Input',async function(){throw Error('prompt callback rejection');})");
  const id = [...host.surfaces.keys()][0];
  host.run(`wg.ui.surfaces().find(function(s){return s.id===${JSON.stringify(id)};}).close()`);
  assert.equal(await prompt, null);
  await host.flush();
  assert.ok(host.logs.some(entry => entry.text.includes("prompt callback rejection")));
  await host.stop();
});

test("capabilities describe implemented leaf methods and reject unsupported siblings", async () => {
  const host = new Host();
  for (const api of ["events.on", "events.once", "events.emit", "events.stream", "bytes.from", "ui.surfaces", "ui.closeAll", "ui.Button", "ui.el.Image", "client.sendFile", "permissions.has"]) {
    assert.equal(host.run(`wg.capabilities.has(${JSON.stringify(api)})`), true, api);
  }
  for (const api of ["ui.el.Web", "ui.ZStack", "tg.invoke", "client.currentChat", "lang.python.run", "net.dns"]) {
    assert.equal(host.run(`wg.capabilities.has(${JSON.stringify(api)})`), false, api);
  }
  await host.stop();
});

test("streams keep only 256 undrained events and reject concurrent pending next calls", async () => {
  const host = new Host();
  host.run("var bounded=wg.events.stream('plugin.buffered')");
  for (let i = 0; i < 300; i++) host.context.__wgNativeEvent("plugin.buffered", { i });
  assert.equal((await host.run("bounded.next()")).value.args[0].i, 44);
  for (let i = 0; i < 255; i++) await host.run("bounded.next()");
  const pending = host.run("bounded.next()");
  await assert.rejects(host.run("bounded.next()"), code("INVALID_ARGUMENT"));
  await host.stop();
  assert.equal((await pending).done, true);
});

test("failed native event byte revival does not poison later transfers", async () => {
  const host = new Host();
  const payload = Array.from({ length: 33 }, () => ({ __wgBase64: "AA==" }));
  assert.throws(() => host.context.__wgNativeEvent("plugin.bytes", payload), code("QUOTA_EXCEEDED"));
  host.run("wg.fs.writeBytes('recovered.bin',new Uint8Array([42]))");
  assert.deepEqual(Array.from(host.run("wg.fs.readBytes('recovered.bin')")), [42]);
  await host.stop();
});
