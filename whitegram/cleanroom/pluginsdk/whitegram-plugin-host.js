    (function() {
        if (!wg.__pluginInstances) return;
        wg.__pluginInstances.forEach(function(plugin) {
            if (plugin && typeof plugin.onUnload === "function") {
                try { plugin.onUnload({ id: wg.pluginId, version: wg.pluginVersion, name: wg.pluginName || wg.pluginId }); } catch (e) { wg.log("onUnload error: " + e); }
            }
        });
    })();