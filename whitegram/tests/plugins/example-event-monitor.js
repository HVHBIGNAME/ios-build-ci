// Enable messages before Run. Open Plugin Controls -> Event monitor.
class EventMonitor extends wg.BasePlugin {
  onLoad() {
    this.entries = [];
    this.total = wg.storage.get("observed", 0);
    wg.settings.registerPage({
      id: "monitor", title: "Event monitor", controls: [
        { id: "enabled", type: "toggle", title: "Observe events", value: true },
        { id: "scope", type: "select", title: "Show", value: "all", options: [
          { title: "All observations", value: "all" }, { title: "Edits and deletions", value: "changes" }
        ] },
        { id: "info", type: "info", title: "Events observe native changes. They cannot cancel a message." },
        { id: "open", type: "button", title: "Open live log", hookName: "plugin.monitor.open" }
      ]
    });
    this.openListener = wg.on("plugin.monitor.open", () => this.show());
  }

  onUpdate(event) {
    if (!wg.settings.getValue("monitor", "enabled", true)) return;
    if (wg.settings.getValue("monitor", "scope", "all") === "changes" &&
        event.type !== "messageEdited" && event.type !== "messageDeleted") return;
    this.total++;
    this.entries.unshift(event.type + " · " + event.peerId + (event.id ? " / " + event.id : ""));
    this.entries = this.entries.slice(0, 25);
    if (this.screen && !this.screen.isClosed) this.screen.update();
  }

  show() {
    if (this.screen && !this.screen.isClosed) { this.screen.show(); return; }
    this.screen = wg.screens.push({ title: "Observed events", render: () => wg.ui.VStack([
      wg.ui.Text("Observed: " + this.total, { font: "headline" }),
      wg.ui.Text(this.entries.length ? this.entries.join("\n") : "Waiting for Telegram activity…"),
      wg.ui.Button("Clear log", () => { this.entries = []; this.screen.update(); })
    ]) });
  }

  onUnload() {
    wg.off("plugin.monitor.open", this.openListener);
    wg.storage.set("observed", this.total);
  }
}

module.exports = EventMonitor;
