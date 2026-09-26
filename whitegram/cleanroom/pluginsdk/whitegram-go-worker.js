importScripts("common.js");
self.__wgBridgeJSON = wgBridgeJSON;
self.__wgCallJSON = wgCallJSON;
self.__wgStdout = function (text) { wgEvent("stdout", String(text)); };
self.__wgStderr = function (text) { wgEvent("stderr", String(text)); };

self.wgInit = async function () {
  var config = wgRuntimeConfig();
  var base = RT_BASE + "go/";
  importScripts(base + (config.support || "wasm_exec.js"));
  var go = new Go();
  var response = await fetch(base + (config.wasm || "yaegi.wasm"));
  var instance = (await WebAssembly.instantiate(await response.arrayBuffer(), go.importObject)).instance;
  go.run(instance);
  for (var i = 0; i < 200 && typeof self.wgGoEval !== "function"; i++) {
    await new Promise(function (resolve) { setTimeout(resolve, 10); });
  }
  if (typeof self.wgGoEval !== "function") throw new Error("Yaegi не запустился");
  var files = wgPackageFiles().filter(function (path) { return /\.go$/i.test(path); });
  for (var j = 0; j < files.length; j++) {
    await goResult(self.wgGoEval(wgReadPackageFile(files[j]), files[j]));
  }
};

async function goResult(promise) {
  var json = await promise;
  var parsed = JSON.parse(json);
  if (parsed.error) throw new Error(parsed.error);
  return parsed.r;
}

handlers.run = async function (p) { return goResult(self.wgGoEval(String(p.code || ""), p.filename || "plugin.go")); };
handlers.eval = handlers.run;
handlers.call = async function (p) { return goResult(self.wgGoCall(String(p.fn), JSON.stringify(p.args || []))); };
handlers.import = async function (p) { return goResult(self.wgGoEval(wgReadPackageFile(String(p.path)), String(p.path))); };
handlers.install = async function () { return []; };