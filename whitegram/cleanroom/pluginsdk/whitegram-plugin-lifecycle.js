    (function() {
        if (!wg.__pluginInstances) wg.__pluginInstances = [];
        var eventMethodMap = {
            onMessageReceive: "onMessageReceive",
            onOutgoingMessage: "onOutgoingMessage",
            onMessageSend: "onMessageSend",
            onChatOpen: "onChatOpen",
            onChatClose: "onChatClose",
            onUpdate: "onUpdate",
            onUpdates: "onUpdates",
            preRequest: "preRequest",
            postRequest: "postRequest",
            onAppForeground: "onAppForeground",
            onAppBackground: "onAppBackground",
            onThemeChange: "onThemeChange",
            onScreenshot: "onScreenshot"
        };
        wg.BasePlugin = function() {};
        wg.BasePlugin.prototype.onLoad = function() {};
        wg.BasePlugin.prototype.onUnload = function() {};
        wg.registerPlugin = function(plugin) {
            if (!plugin) return plugin;
            wg.__pluginInstances.push(plugin);
            Object.keys(eventMethodMap).forEach(function(eventName) {
                var methodName = eventMethodMap[eventName];
                if (typeof plugin[methodName] === "function") {
                    wg.on(eventName, function() {
                        return plugin[methodName].apply(plugin, arguments);
                    });
                }
            });
            if (typeof plugin.onLoad === "function") {
                plugin.onLoad({ id: wg.pluginId, version: wg.pluginVersion, name: wg.pluginName || wg.pluginId });
            }
            return plugin;
        };
        wg.hook = function(eventName, callback) {
            wg.on(eventName, callback);
            return callback;
        };
        wg.HookStrategy = {
            CONTINUE: "continue",
            CANCEL: "cancel",
            MODIFY: "modify",
            MODIFY_FINAL: "modifyFinal"
        };
        wg.HookResult = {
            continue: function(value) { return { strategy: "continue", value: value }; },
            cancel: function(reason) { return { strategy: "cancel", reason: reason || "" }; },
            modify: function(value) { return { strategy: "modify", value: value }; },
            modifyFinal: function(value) { return { strategy: "modifyFinal", value: value }; }
        };
        // MARK: Whitegram — ExteraGram-совместимые имена хуков поверх той же системы.
        //
        // На iOS нет Xposed: нельзя перехватывать произвольные классы Telegram в рантайме.
        // Поэтому app-side перехват идёт через точки, которые Whitegram открывает сам, а
        // эти алиасы дают привычную плагиноделам форму. Колбэк возвращает wg.HookResult.*.
        // Список ЖИВЫХ доменов override отдаёт wg.override.domains().
        wg.override = function(domain, callback) { return wg.on("override:" + String(domain), callback); };
        wg.onRequest = function(callback) { return wg.on("preRequest", callback); };
        wg.onResponse = function(callback) { return wg.on("postRequest", callback); };
        wg.onUpdate = function(callback) { return wg.on("onUpdate", callback); };
        wg.onSendMessage = function(callback) { return wg.on("onSendMessage", callback); };
        wg.httpGet = function(url, callback) {
            return wg.fetch(String(url), function(error, body) {
                (callback || function(){})(error ? { ok: false, error: error, body: null, status: 0 } : { ok: true, error: null, body: body, status: 200 });
            });
        };
        wg.httpPost = function(url, body, callback) {
            return wg.fetchPost(String(url), body || {}, {}, function(error, responseBody) {
                (callback || function(){})(error ? { ok: false, error: error, body: null, status: 0 } : { ok: true, error: null, body: responseBody, status: 200 });
            });
        };
        wg.reply = function(peerId, messageId, text, callback) {
            return wg.sendTextMessage(String(peerId), String(text), callback || function(){});
        };
        wg.client = {
            sendMessage: function(peerId, text, callback) {
                return wg.sendTextMessage(String(peerId), String(text), callback || function(){});
            },
            sendFile: function(peerId, path, options, callback) {
                options = options || {};
                return wg.sendFileMessage(String(peerId), String(path), String(options.caption || ""), String(options.mimeType || ""), callback || function(){});
            },
            sendDice: function(peerId, emoji, callback) {
                return wg.sendDiceMessage(String(peerId), String(emoji || "🎲"), callback || function(){});
            },
            sendLocation: function(peerId, latitude, longitude, callback) {
                return wg.sendLocationMessage(String(peerId), Number(latitude), Number(longitude), callback || function(){});
            },
            sendContact: function(peerId, contact, callback) {
                contact = contact || {};
                return wg.sendContactMessage(String(peerId), String(contact.firstName || ""), String(contact.lastName || ""), String(contact.phone || contact.phoneNumber || ""), callback || function(){});
            },
            editMessage: function(peerId, messageId, text) {
                return wg.editMessage(String(peerId), Number(messageId), String(text));
            },
            currentChat: function() {
                return wg.getCurrentChat();
            },
            getMessages: function(peerId, limit, offsetId, callback) {
                return wg.getMessages(String(peerId), limit || 50, offsetId || 0, callback || function(){});
            },
            getPeer: function(peerId, callback) {
                return wg.getPeer(String(peerId), callback || function(){});
            }
        };
        wg.invoke = function(action, params, callback) {
            params = params || {};
            callback = callback || function(){};
            try {
                switch (String(action)) {
                case "client.getMe": return wg.getMe(callback);
                case "client.getCurrentChat": return callback({ ok: true, result: wg.getCurrentChat() });
                case "client.openChat": return callback({ ok: true, result: wg.openChat(String(params.peerId || params.id || "")) });
                case "client.getChatList": return wg.getChatList(Number(params.limit || 50), function(result) { callback({ ok: true, result: result }); });
                case "client.getMessages": return wg.getMessages(String(params.peerId || ""), Number(params.limit || 50), Number(params.offsetId || 0), function(result) { callback({ ok: true, result: result }); });
                case "client.getPeer": return wg.getPeer(String(params.peerId || params.id || ""), function(result) { callback({ ok: true, result: result }); });
                case "client.sendText": return wg.sendTextMessage(String(params.peerId || ""), String(params.text || ""), function(result) { callback({ ok: !!result, result: result }); });
                case "client.sendFile": return wg.sendFileMessage(String(params.peerId || ""), String(params.path || ""), String(params.caption || ""), String(params.mimeType || ""), function(result) { callback({ ok: !!result, result: result }); });
                case "client.sendDice": return wg.sendDiceMessage(String(params.peerId || ""), String(params.emoji || "🎲"), function(result) { callback({ ok: !!result, result: result }); });
                case "client.sendLocation": return wg.sendLocationMessage(String(params.peerId || ""), Number(params.latitude || 0), Number(params.longitude || 0), function(result) { callback({ ok: !!result, result: result }); });
                case "client.sendContact": return wg.sendContactMessage(String(params.peerId || ""), String(params.firstName || ""), String(params.lastName || ""), String(params.phone || ""), function(result) { callback({ ok: !!result, result: result }); });
                case "client.editMessage": wg.editMessage(String(params.peerId || ""), Number(params.messageId || params.msgId || 0), String(params.text || "")); return callback({ ok: true });
                case "client.deleteMessage": wg.deleteMessage(String(params.peerId || ""), Number(params.messageId || params.msgId || 0)); return callback({ ok: true });
                case "client.react": wg.reactToMessage(String(params.peerId || ""), Number(params.messageId || params.msgId || 0), String(params.emoji || "")); return callback({ ok: true });
                case "client.pinMessage": wg.pinMessage(String(params.peerId || ""), Number(params.messageId || params.msgId || 0), !!params.pinned); return callback({ ok: true });
                case "client.forwardMessage": wg.forwardMessage(String(params.fromPeerId || ""), Number(params.messageId || params.msgId || 0), String(params.toPeerId || "")); return callback({ ok: true });
                case "client.markRead": wg.markChatAsRead(String(params.peerId || "")); return callback({ ok: true });
                case "tg.raw": return wg.tg.sendRawRequest(String(params.method || ""), params.params || {}, callback);
                case "tg.postbox": return wg.tg.postbox(params, function(result) { callback({ ok: true, result: result }); });
                default:
                    if (wg.tg && typeof wg.tg[String(action).replace(/^tg\./, "")] === "function") {
                        return callback({ ok: false, error: "DIRECT_TG_ACTION_REQUIRES_TYPED_CALL", action: String(action) });
                    }
                    return callback({ ok: false, error: "UNSUPPORTED_ACTION", action: String(action) });
                }
            } catch (e) {
                return callback({ ok: false, error: String(e), action: String(action) });
            }
        };
        wg.client.invoke = wg.invoke;
        wg.settings = {
            addRow: function(config) { return wg.addSettingsRow(config || {}); },
            registerPage: function(config) { return wg.registerSettingsPage(config || {}); },
            openPage: function(pageId) { return wg.openSettingsPage(String(pageId || "main")); },
            getValue: function(pageId, controlId, defaultValue) { return wg.getSettingsValue(String(pageId || "main"), String(controlId), defaultValue); },
            setValue: function(pageId, controlId, value) { return wg.setSettingsValue(String(pageId || "main"), String(controlId), value); },
            addSwitch: function(key, title, defaultValue, subtitle) {
                var eventName = "settings:" + String(key);
                wg.addSettingsRow({ id: String(key), title: String(title || key), subtitle: String(subtitle || ""), hookName: eventName });
                return eventName;
            }
        };
        wg.menu = {
            addItem: function(config) { return wg.addMenuItem(config || {}); },
            addMessageItem: function(id, title, hookName, icon) {
                return wg.addMenuItem({ id: String(id), title: String(title), hookName: String(hookName), icon: icon || "", locations: ["message"] });
            }
        };
    })();