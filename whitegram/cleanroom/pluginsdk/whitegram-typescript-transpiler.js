    var __wgTS = (typeof ts !== "undefined") ? ts : module.exports;
    function __wgTranspile(source, fileName) {
        var result = __wgTS.transpileModule(source, {
            fileName: fileName,
            reportDiagnostics: true,
            compilerOptions: {
                target: __wgTS.ScriptTarget.ES2020,
                module: __wgTS.ModuleKind.CommonJS,
                esModuleInterop: true,
                jsx: __wgTS.JsxEmit.React
            }
        });
        var errors = (result.diagnostics || []).filter(function (d) { return d.category === __wgTS.DiagnosticCategory.Error; });
        if (errors.length) {
            var d = errors[0];
            var text = __wgTS.flattenDiagnosticMessageText(d.messageText, "\n");
            if (d.file && d.start !== undefined) {
                var pos = d.file.getLineAndCharacterOfPosition(d.start);
                text = fileName + ":" + (pos.line + 1) + ":" + (pos.character + 1) + " " + text;
            }
            return { ok: false, error: text };
        }
        return { ok: true, code: result.outputText };
    }