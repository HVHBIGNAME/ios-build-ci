    (function() {
        var gate = __wgPermissionGate;
        var table = __wgPermissionTable;
        Object.keys(table).forEach(function(path) {
            var parts = path.split(".");
            var owner = wg;
            for (var i = 0; i < parts.length - 1; i++) {
                owner = owner && owner[parts[i]];
            }
            if (!owner) return;
            var key = parts[parts.length - 1];
            var original = owner[key];
            if (typeof original !== "function") return;
            var permission = table[path];
            owner[key] = function() {
                if (!gate(permission, path)) {
                    throw new Error("Whitegram: wg." + path + " — нет разрешения «" + permission + "»");
                }
                return original.apply(this, arguments);
            };
        });
    })();