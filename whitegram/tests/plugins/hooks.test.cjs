"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const { NativeHostFixture: Host, sdkDirectory, telegramEvents } = require("./native-host-fixture.cjs");

const plain = value => JSON.parse(JSON.stringify(value));
const code = expected => error => error?.code === expected;

test("recovered execution resources retain the original extraction hashes", () => {
  // recovered-3.1.1/manifest.json, embedded_sources. The native bootstrap is a
  // separate host addition and deliberately has no recovered-file hash.
  const hashes = {
    "whitegram-sdk-core.js": "96d89247b19c63925be566b949036cbc45040248db3206a264c56d0d65bf9b3d",
    "whitegram-plugin-lifecycle.js": "477330d74d611b6b3ada22b79b2407db303f5bf7ac18b09d7f4d43f8a606b4f9",
    "whitegram-sdk-extensions.js": "8c7bf3946b42c39a0f280e62550d1fcec6d50d71f1ae62eba3ea6f8617555e49",
    "whitegram-sdk-bridge.js": "d5f595fdf1346a8da054733b000d863c310fd1de1bb7eb0d7d52ea7f7644e3f0",
    "whitegram-plugin-host.js": "9839d4369f98344b03d31de626514422143822215cb6ede764b6e01f3f797efa"
  };
  for (const [name, expected] of Object.entries(hashes)) {
    assert.equal(crypto.createHash("sha256").update(fs.readFileSync(path.join(sdkDirectory, name))).digest("hex"), expected, name);
  }
});

test("legacy on/hook and SDK event patterns share native interest until the last removal", async () => {
  const host = new Host({ grants: { messages: true } });
  host.run(`var seen=[]; var first=wg.on('onMessageReceive',function(p){seen.push(p.id);});
    var second=wg.events.on('onMessage*',function(p,n){seen.push(n);});`);
  assert.deepEqual([...host.eventSubscriptions].sort(), ["onMessageReceive", "onMessageSend"]);
  host.run("wg.off('onMessageReceive',first)");
  assert.equal(host.eventSubscriptions.has("onMessageReceive"), true);
  host.context.__wgNativeEvent("onMessageReceive", { id: 41, text: "native fixture" });
  assert.deepEqual(plain(host.run("seen")), ["onMessageReceive"]);
  host.run("wg.events.off('onMessage*',second)");
  assert.equal(host.eventSubscriptions.size, 0);
  host.run("var hook=wg.hook('onMessageReceive',function(p){seen.push(p.id);});wg.off('onMessageReceive',hook)");
  assert.equal(host.eventSubscriptions.size, 0);
  await host.stop();
});

test("onUpdate, tg.update, once and streams retain the recovered registration contracts", async () => {
  const host = new Host({ grants: { messages: true } });
  host.run(`var changes=[]; var once=wg.events.once('onUpdate',function(p){changes.push(p.type);});
    var updates=wg.events.stream('tg.*'); var alias=wg.onUpdate(function(p){changes.push(p.id);});`);
  assert.deepEqual([...host.eventSubscriptions], ["tg.update"]);
  const next = host.run("updates.next()");
  host.context.__wgNativeEvent("tg.update", { id: 1, type: "messageEdited", scope: "postbox" });
  assert.equal((await next).value.name, "tg.update");
  host.context.__wgNativeEvent("tg.update", { id: 2, type: "messageDeleted", scope: "postbox" });
  assert.deepEqual(plain(host.run("changes")), [1, "messageEdited", 2]);
  host.run("wg.off('onUpdate',alias);updates.return()");
  assert.equal(host.eventSubscriptions.size, 0);
  await host.stop();
});

test("exported hook-only plugins register once and receive queued and sent phases separately", async () => {
  const host = new Host({ grants: { messages: true } });
  await host.entry(`var phases=[]; module.exports=Object.freeze({
    onMessageReceive:function(p){phases.push(['received',p.id]);},
    onOutgoingMessage:function(p){phases.push(['queued',p.id]);},
    onMessageSend:function(p){phases.push(['sent',p.id]);},
    onChatOpen:function(p){phases.push(['opened',p.peerId]);},
    onChatClose:function(p){phases.push(['closed',p.peerId]);},
    onUpdate:function(p){phases.push(['update',p.type]);},
    onUpdates:function(p){phases.push(['batch',p.updates.length]);}
  });wg.registerPlugin(module.exports);`);
  assert.equal(host.run("wg.__pluginInstances.length"), 1);
  assert.deepEqual([...host.eventSubscriptions].sort(), [...telegramEvents].sort());
  for (const [name, payload] of [
    ["onMessageReceive", { id: 8 }], ["onOutgoingMessage", { id: 900, queued: true }],
    ["onMessageSend", { id: 9, localId: { id: 900, namespace: 1 }, sent: true }],
    ["onChatOpen", { peerId: "123" }], ["onChatClose", { peerId: "123" }],
    ["tg.update", { type: "messageEdited" }], ["onUpdates", { updates: [{ type: "messageDeleted" }] }]
  ]) host.context.__wgNativeEvent(name, payload);
  assert.deepEqual(plain(host.run("phases")), [["received", 8], ["queued", 900], ["sent", 9], ["opened", "123"], ["closed", "123"], ["update", "messageEdited"], ["batch", 1]]);
  await host.stop();
  host.context.__wgNativeEvent("onMessageReceive", { id: 99 });
  assert.equal(host.run("phases.length"), 7);
  assert.equal(host.eventSubscriptions.size, 0);
});

test("message permissions cover exact, wildcard, lifecycle and low-level registrations", async () => {
  const host = new Host();
  for (const source of [
    "wg.on('onMessageReceive',function(){})", "wg.events.on('tg.*',function(){})", "wg.events.on('*',function(){})",
    "wg.__sdk.subscribe('onOutgoingMessage')", "wg.registerPlugin({onChatOpen:function(){}})"
  ]) assert.throws(() => host.run(source), code("PERMISSION_DENIED"), source);
  assert.equal(host.run("wg.__pluginInstances.length"), 0);
  const denied = JSON.parse(host.hostSync("events.setSubscriptions", JSON.stringify([["onMessageReceive"]])));
  assert.equal(denied.error.code, "PERMISSION_DENIED");
  assert.throws(() => host.run("wg.events.on('onMessageEdited',function(){})"), code("UNSUPPORTED_API"));
  assert.throws(() => host.run("wg.__sdk.subscribe('tg.unimplemented')"), code("UNSUPPORTED_API"));
  host.grants.messages = true;
  host.run("var count=0;wg.events.on('tg.*',function(){count++;});wg.on('onMessageReceive',function(){count++;});");
  host.grants.messages = false;
  host.context.__wgNativeEvent("onMessageReceive", { id: 1 });
  host.context.__wgSDKEvent("tg.update", { type: "messageDeleted" });
  assert.equal(host.run("count"), 0);
  host.run("wg.events.off('tg.*');wg.off('onMessageReceive')");
  assert.equal(host.eventSubscriptions.size, 0);
  await host.stop();
});

test("a failed native registration leaves no poisoned SDK bucket or partial plugin instance", async () => {
  const host = new Host({ grants: { messages: true } });
  const sync = host.sync.bind(host);
  let failOnce = true;
  host.sync = (name, args) => {
    if (name === "events.setSubscriptions" && failOnce) {
      failOnce = false;
      throw Object.assign(new Error("registration failed"), { code: "BRIDGE_ERROR" });
    }
    return sync(name, args);
  };
  assert.throws(() => host.run("wg.events.on('onMessageReceive',function(){})"), code("BRIDGE_ERROR"));
  host.run("var count=0;wg.events.on('onMessageReceive',function(){count++;});");
  host.context.__wgNativeEvent("onMessageReceive", {});
  assert.equal(host.run("count"), 1);
  host.run("for(var i=0;i<255;i++)wg.on('plugin.test',function(){});");
  assert.throws(() => host.run("wg.registerPlugin({onMessageSend:function(){},onChatOpen:function(){}})"), code("QUOTA_EXCEEDED"));
  assert.equal(host.run("wg.__pluginInstances.length"), 0);
  assert.equal(host.eventSubscriptions.has("onMessageSend"), false);
  await host.stop();
});

test("observational HookResults cannot pretend to cancel and async hook failures reach logs", async () => {
  const host = new Host({ grants: { messages: true } });
  host.run(`var observed=0;
    wg.hook('onOutgoingMessage',function(){return wg.HookResult.cancel('no');});
    wg.events.on('onOutgoingMessage',async function(){throw Error('async hook failed');});
    wg.on('onOutgoingMessage',function(){observed++;});`);
  host.context.__wgNativeEvent("onOutgoingMessage", { queued: true, id: 5, interceptable: false });
  await host.flush();
  assert.equal(host.run("observed"), 1);
  assert.ok(host.logs.some(item => item.text.includes("cannot change the Telegram operation")));
  assert.ok(host.logs.some(item => item.text.includes("async hook failed")));
  assert.equal(host.run("wg.capabilities.feature('globalTelegramEvents')"), true);
  assert.equal(host.run("wg.capabilities.has('intercept')"), false);
  for (const source of ["wg.onRequest(function(){})", "wg.onResponse(function(){})", "wg.onSendMessage(function(){})", "wg.override('send',function(){})"]) {
    assert.throws(() => host.run(source), code("UNSUPPORTED_API"));
  }
  await host.stop();
});

test("current-chat root/client/invoke APIs report the host snapshot or null", async () => {
  const host = new Host({ grants: { messages: true } });
  assert.equal(host.run("wg.getCurrentChat()"), null);
  host.currentChat = { id: "123", peerId: "123", threadId: "42", title: "Example", viewId: "native-view" };
  assert.deepEqual(plain(host.run("wg.client.currentChat()")), host.currentChat);
  assert.deepEqual(plain(await host.run("wg.invoke('client.getCurrentChat')")), host.currentChat);
  host.grants.messages = false;
  assert.throws(() => host.run("wg.client.currentChat()"), /messages/);
  await host.stop();
});

test("registered settings pages appear in native metadata and lazily render persisted controls", async () => {
  const host = new Host();
  host.run(`var changed=[]; wg.settings.registerPage({id:'prefs',title:'Plugin preferences',controls:[
    {id:'enabled',type:'switch',title:'Enabled',value:false,hookName:'plugin.enabled'},
    {id:'volume',type:'slider',title:'Volume',min:0,max:10,value:3},
    {id:'label',type:'text',title:'Label',value:'start'}
  ]});wg.on('plugin.enabled',function(p){changed.push(p);});`);
  assert.equal(host.settingsItems.get("page:prefs").title, "Plugin preferences");
  assert.equal(host.surfaces.size, 0);
  host.activateSettingsItem("page:prefs");
  const [id] = host.surfaces.keys();
  let tree = host.surface(id).tree;
  assert.equal(tree.children[0].type, "toggle");
  host.context.__wgUIDispatch(id, tree.children[0].props.onChange.slice(5), { value: true });
  assert.equal(host.storage["settings:prefs:enabled"], true);
  assert.equal(host.surface(id).tree.children[0].props.value, true);
  assert.deepEqual(plain(host.run("changed")), [{ pageId: "prefs", controlId: "enabled", value: true }]);
  tree = host.surface(id).tree;
  host.context.__wgUIDispatch(id, tree.children[2].children[1].props.onChange.slice(5), { value: "saved" });
  assert.equal(host.storage["settings:prefs:label"], "saved");
  host.run("wg.settings.setValue('prefs','volume',7)");
  assert.equal(host.surface(id).tree.children[1].props.value, 7);
  host.activateSettingsItem("page:prefs");
  assert.equal(host.surfaces.size, 1);
  await host.stop();
  assert.equal(host.settingsItems.size, 0);
});

test("re-registering pages and rows replaces callbacks; stale native tokens cannot reopen UI", async () => {
  const host = new Host();
  host.run("var actions=0;wg.settings.registerPage({id:'p',title:'Old',controls:[]});wg.settings.addRow({id:'r',title:'Old row',hookName:'plugin.old'});wg.on('plugin.old',function(){actions++;});");
  const oldPage = host.settingsItems.get("page:p"), oldRow = host.settingsItems.get("row:r");
  host.activateSettingsItem("page:p");
  const [id] = host.surfaces.keys();
  host.run("wg.settings.registerPage({id:'p',title:'New',controls:[{id:'s',type:'switch',title:'New control',value:true}]});wg.settings.addRow({id:'r',title:'New row',hookName:'plugin.new'});wg.on('plugin.new',function(){actions+=10;});");
  assert.equal(host.surface(id).options.title, "New");
  assert.equal(host.surface(id).tree.children[0].props.value, true);
  host.context.__wgUIDispatch("__settings", oldRow.token, { kind: "row", id: "r" });
  host.context.__wgUIDispatch("__settings", oldPage.token, { kind: "page", id: "p" });
  assert.equal(host.run("actions"), 0);
  host.activateSettingsItem("row:r");
  assert.equal(host.run("actions"), 10);
  assert.equal(host.settingsItems.size, 2);
  await host.stop();
  host.context.__wgUIDispatch("__settings", oldPage.token, { kind: "page", id: "p" });
  assert.equal(host.surfaces.size, 0);
});

test("settings registration errors, quotas and permission revocation leave bounded state", async () => {
  const host = new Host();
  assert.throws(() => host.run("wg.settings.registerPage({controls:[{id:'x',type:'guessed-native-widget'}]})"), code("UNSUPPORTED_SETTINGS_CONTROL"));
  assert.throws(() => host.run("wg.settings.registerPage({controls:[{id:'x',type:'slider',min:2,max:1}]})"), code("INVALID_ARGUMENT"));
  assert.throws(() => host.run("wg.settings.registerPage({controls:[{id:'x'},{id:'x'}]})"), code("INVALID_ARGUMENT"));
  assert.equal(host.settingsItems.size, 0);
  host.run("for(var i=0;i<8;i++)wg.settings.registerPage({id:'page'+i,title:'Page '+i});");
  assert.throws(() => host.run("wg.settings.registerPage({id:'ninth'})"), code("QUOTA_EXCEEDED"));
  assert.throws(() => host.run("wg.settings.openPage('ninth')"), code("SETTINGS_PAGE_NOT_FOUND"));
  host.run("wg.settings.registerPage({id:'page0',title:'Replacement'});");
  assert.equal(host.settingsItems.size, 8);
  host.grants.uiMutation = false;
  host.activateSettingsItem("page:page0");
  assert.equal(host.surfaces.size, 0);
  assert.throws(() => host.run("wg.settings.openPage('page0')"), /uiMutation/);
  assert.throws(() => host.run("wg.settings.addRow({id:'blocked',title:'Blocked'})"), /uiMutation/);
  await host.stop();
});

test("the recovered settings-page row routing convention opens its registered page", async () => {
  const host = new Host();
  host.run("wg.settings.registerPage({id:'p',title:'Page'});wg.settings.addRow({id:'open',title:'Open page',hookName:'__wg_open_settings_page:p'});");
  host.activateSettingsItem("row:open");
  assert.equal(host.surfaces.size, 1);
  assert.equal([...host.surfaces.values()][0].options.title, "Page");
  await host.stop();
});

test("native-evidenced settings aliases and option title/label/value rules stay connected", async () => {
  const host = new Host();
  host.run(`wg.settings.registerPage({id:'aliases',controls:[
    {id:'enabled',type:'toggle',title:'Enabled',value:true},
    {id:'range',type:'slider',title:'Range'},
    {id:'notes',type:'input',title:'Notes',value:'a'},
    {id:'label',type:'label',title:'Read only'}, {id:'info',type:'info',title:'Information'},
    {id:'selection',type:'menu',title:'Choice',options:[{label:'First',value:'one'},{title:'Second'},{value:'third'}]}
  ]});wg.openSettingsPage('aliases');`);
  const [id] = host.surfaces.keys();
  const tree = host.surface(id).tree;
  assert.equal(tree.children[0].type, "toggle");
  assert.equal(tree.children[1].props.max, 100);
  assert.equal(tree.children[2].children[1].type, "textfield");
  assert.equal(tree.children[3].type, "text");
  assert.equal(tree.children[4].type, "text");
  host.context.__wgUIDispatch(id, tree.children[5].props.onTap.slice(5), { value: null });
  assert.deepEqual(host.nextRequest("ui.actionSheet").args[2], ["First", "Second", "third"]);
  host.settle("ui.actionSheet", 1);
  await host.flush();
  assert.equal(host.storage["settings:aliases:selection"], "Second");
  const nextTree = host.surface(id).tree;
  host.context.__wgUIDispatch(id, nextTree.children[5].props.onTap.slice(5), { value: null });
  host.run("wg.ui.closeAll()");
  await host.flush();
  host.settle("ui.actionSheet", 2);
  await host.flush();
  assert.equal(host.storage["settings:aliases:selection"], "Second", "late selection after closing the page must be discarded");
  await host.stop();
});

test("an exported app-only lifecycle object receives its original alias", async () => {
  const host = new Host();
  await host.entry("var foregrounds=0;module.exports={onAppForeground:function(){foregrounds++;}};");
  host.context.__wgNativeEvent("app.foreground", {});
  assert.equal(host.run("foregrounds"), 1);
  await host.stop();
});

test("the event monitor example uses native settings activation, live rerender and unload persistence", async () => {
  const host = new Host({ grants: { messages: true } });
  await host.entry(fs.readFileSync(path.join(__dirname, "example-event-monitor.js"), "utf8"));
  assert.equal(host.state, "running");
  assert.deepEqual([...host.eventSubscriptions], ["tg.update"]);
  host.activateSettingsItem("page:monitor");
  const [settingsId] = host.surfaces.keys();
  host.context.__wgUIDispatch(settingsId, host.surface(settingsId).tree.children[3].props.onTap.slice(5), { value: null });
  const logId = [...host.surfaces.keys()][1];
  host.context.__wgNativeEvent("tg.update", { type: "messageEdited", id: 8, peerId: "123" });
  assert.equal(host.surface(logId).tree.children[0].props.text, "Observed: 1");
  assert.equal(host.surface(logId).tree.children[1].props.text, "messageEdited · 123 / 8");
  host.run("wg.settings.setValue('monitor','enabled',false)");
  host.context.__wgNativeEvent("tg.update", { type: "messageReceived", id: 9, peerId: "123" });
  assert.equal(host.surface(logId).tree.children[0].props.text, "Observed: 1");
  assert.equal(host.pending.size, 0, "the observer must not send Telegram messages");
  await host.stop();
  assert.equal(host.storage.observed, 1);
  assert.equal(host.settingsItems.size, 0);
});
