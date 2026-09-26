importScripts("common.js");
var vm = null;

self.wgInit = async function () {
  var config = wgRuntimeConfig();
  var base = RT_BASE + "ruby/";
  importScripts(base + (config.entry || "browser.umd.js"));
  var api = self[config.global || "ruby-wasm-wasi"];
  var response = await fetch(base + (config.wasm || "ruby.wasm"));
  var module = await WebAssembly.compile(await response.arrayBuffer());
  var created = await api.DefaultRubyVM(module, { consolePrint: true });
  vm = created.vm;
  self.__wgCallJSON = wgCallJSON;
  self.__wgBridgeJSON = wgBridgeJSON;
  self.__wgReadPackageFile = function (path) { return wgReadPackageFile(path); };
  vm.eval([
    "require 'js'",
    "require 'json'",
    "module WG",
    "  class NS < BasicObject",
    "    def initialize(prefix) @prefix = prefix end",
    "    def method_missing(name, *args)",
    "      path = @prefix.empty? ? name.to_s : \"#{@prefix}.#{name}\"",
    "      return NS.new(path) if args.empty? && !name.to_s.end_with?('!')",
    "      ::JSON.parse(::JS.global.call(:__wgCallJSON, path.delete_suffix('!'), ::JSON.generate(args)).to_s)['r']",
    "    end",
    "    def respond_to_missing?(*) true end",
    "  end",
    "  def self.call(path, *args) ::JSON.parse(JS.global.call(:__wgCallJSON, path, ::JSON.generate(args)).to_s)['r'] end",
    "  def self.bridge(op, payload = {}) ::JSON.parse(JS.global.call(:__wgBridgeJSON, op, ::JSON.generate(payload)).to_s)['r'] end",
    "  # Прямой вызов других языков плагина: WG.lang(:go).Hello('Макс'), WG.lang(:python).call('tools.check', host)",
    "  class Lang",
    "    def initialize(name) @name = name.to_s end",
    "    def call(fn, *args) WG.call(\"lang.#{@name}.call\", fn.to_s, *args) end",
    "    def run(code) WG.call(\"lang.#{@name}.run\", code) end",
    "    def load(path) WG.call(\"lang.#{@name}.import\", path) end",
    "    def method_missing(fn, *args) call(fn, *args) end",
    "    def respond_to_missing?(*) true end",
    "  end",
    "  def self.lang(name) Lang.new(name) end",
    "end",
    "$wg = WG::NS.new('')",
    "def wg; $wg; end",
    "def lang(name); WG.lang(name); end",
    "# Загрузка файлов пакета: wg_require 'lib/helper' (ищет .rb в пакете плагина)",
    "def wg_require(path)",
    "  path = path.end_with?('.rb') ? path : path + '.rb'",
    "  @__wg_loaded ||= {}",
    "  return false if @__wg_loaded[path]",
    "  @__wg_loaded[path] = true",
    "  TOPLEVEL_BINDING.eval(JS.global.call(:__wgReadPackageFile, path).to_s, path)",
    "  true",
    "end"
  ].join("\n"));
};

// Ошибка Ruby без внутренних строк обвязки ruby.wasm (/bundle/gems/js-…).
function rubyError(error) {
  var text = String(error && error.message ? error.message : error);
  var lines = text.split("\n").filter(function (line) { return line.indexOf("/bundle/gems/js-") === -1; });
  return new Error(lines.join("\n").replace(/^eval_async:(\d+):in `<main>': /, "строка $1: "));
}

handlers.run = async function (p) {
  var result;
  try { result = await vm.evalAsync(String(p.code || "")); } catch (e) { throw rubyError(e); }
  var json = result.call("to_json").toString();
  try { return JSON.parse(json); } catch (e) { return result.toString(); }
};
handlers.eval = handlers.run;
var rubyCall = function (p) {
  self.__wgArgs = JSON.stringify(p.args || []);
  var fn = String(p.fn);
  var dot = fn.lastIndexOf(".");
  var code;
  if (dot > 0) {
    code = fn.substring(0, dot).replace(/\./g, "::") + "." + fn.substring(dot + 1) + "(*JSON.parse(JS.global[:__wgArgs].to_s)).to_json";
  } else {
    code = fn + "(*JSON.parse(JS.global[:__wgArgs].to_s)).to_json";
  }
  var json = vm.eval(code).toString();
  try { return JSON.parse(json); } catch (e) { return json; }
};
handlers.call = async function (p) {
  try { return rubyCall(p); } catch (e) { throw rubyError(e); }
};
handlers.import = async function (p) {
  try { vm.eval("wg_require " + JSON.stringify(String(p.path || p.module || ""))); } catch (e) { throw rubyError(e); }
  return true;
};
handlers.install = async function () { return []; };