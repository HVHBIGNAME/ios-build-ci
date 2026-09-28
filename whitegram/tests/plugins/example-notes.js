// Import this file through Whitegram Plugins. Local editing needs only the
// default storage/uiMutation permissions. Sending needs account + messages.
module.exports = {
  onLoad: function () {
    var ui = wg.ui;
    this.surface = ui.sheet({
      title: "Plugin Notes",
      state: { note: wg.storage.get("note", ""), status: "Saved on this device" },
      render: function (state, screen) {
        function save() {
          wg.storage.set("note", state.note);
          screen.setState({ status: "Saved locally" });
        }
        function send() {
          Promise.resolve().then(function () { return wg.getMe(); }).then(function (me) {
            return wg.sendTextMessage(me.id, state.note);
          }).then(function (result) {
            screen.setState({ status: "Queued in Saved Messages (" + result.messageIds[0].id + ")" });
          }).catch(function (error) {
            console.error(error);
            screen.setState({ status: error.message });
          });
        }
        return ui.VStack({ spacing: 14 }, [
          ui.Text("A native screen driven by the recovered SDK", { bold: true }),
          ui.TextArea({ id: "note", bind: "note", rerender: false, height: 180 }),
          ui.HStack({ distribution: "equal" }, [ui.Button("Save locally", save), ui.Button("Send to Saved Messages", send)]),
          ui.Text(state.status, { secondary: true, font: "footnote" })
        ]);
      }
    });
  },
  onUnload: function () {
    if (this.surface) wg.storage.set("note", this.surface.state.note);
    console.info("Notes plugin stopped");
  }
};
