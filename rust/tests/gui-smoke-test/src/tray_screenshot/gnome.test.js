const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const { test } = require("node:test");
const vm = require("node:vm");

test("refreshes a stale AppIndicator menu, with a bounded retry count", async () => {
  const session = fixture();
  session.root.items[0].label.text = "";
  await session.poll();
  await session.poll();

  for (let attempt = 1; attempt <= 3; attempt++) {
    session.advance(5_000_000);
    assert.equal(await session.poll(), false);
    assert.equal(session.client.refreshes, attempt);
    assert.equal(session.client._flagItemsUpdateRequired, true);
  }
  session.advance(5_000_000);
  await assert.rejects(session.poll(), /stale after three refreshes/);

  session.root.items[0].label.text = "Engineering wiki";
  await session.finish();
  assert.equal(session.helper.refreshes, 3);
});

test("waits for every label, icon and rendered geometry before capturing", async () => {
  const session = fixture();
  const item = session.submenu.items[0];
  item.label.text = "";
  item._icon.gicon = null;
  for (let i = 0; i < 5; i++) assert.equal(await session.poll(), false);
  assert.equal(session.submenu.isOpen, false);

  item.label.text = "Gateway connected";
  for (let i = 0; i < 5; i++) assert.equal(await session.poll(), false);
  assert.equal(session.submenu.isOpen, false);

  item._icon.gicon = {};
  await session.finish();
  assert.equal(session.client.refreshes, 0);
  assert.ok(session.submenu.openedFrame >= session.root.openedFrame + 2);
  assert.ok(session.helper.frames >= session.submenu.openedFrame + 2);

  session.submenu.actor.height += 10;
  assert.equal(await session.poll(), false);
  await session.finish();
});

function fixture() {
  let now = 0;
  let paint;
  const client = {
    refreshes: 0,
    _requestLayoutUpdate() {
      this.refreshes++;
    },
    async GetLayoutAsync() {
      const variant = (value) => ({ deep_unpack: () => value });
      return [
        1,
        [
          0,
          {},
          [
            variant([
              1,
              { label: variant("Engineering wiki") },
              [
                variant([
                  2,
                  {
                    label: variant("Gateway connected"),
                    "icon-data": variant([1]),
                  },
                  [],
                ]),
              ],
            ]),
          ],
        ],
      ];
    },
  };
  const context = vm.createContext({
    console: { log() {} },
    Gio: { Resource: { load: () => ({ _register() {} }) } },
    GLib: { get_monotonic_time: () => now },
    Main: {
      setThemeStylesheet() {},
      loadTheme() {},
      overview: { hide() {} },
      panel: { statusArea: {} },
    },
    global: {
      get_window_actors: () => [],
      stage: {
        connect(_signal, callback) {
          paint = callback;
        },
        queue_redraw() {},
      },
    },
  });
  vm.runInContext(
    fs.readFileSync(path.join(__dirname, "gnome.js"), "utf8"),
    context
  );
  const helper = context.global.firezoneScreenshot;
  helper.prepare("theme", "stylesheet");
  const submenu = menu([entry(2, "Gateway connected", null, {})]);
  const root = menu([entry(1, "Engineering wiki", submenu)]);
  context.Main.panel.statusArea.indicator = {
    _indicator: { id: "dev.firezone.client" },
    _menuClient: { _client: client },
    menu: root,
  };
  return {
    client,
    helper,
    root,
    submenu,
    advance(duration) {
      now += duration;
    },
    async poll() {
      const ready = helper.open("Engineering wiki");
      await new Promise(setImmediate);
      paint();
      return ready;
    },
    async finish() {
      for (let i = 0; i < 20; i++) if (await this.poll()) return;
      assert.fail("Menu did not become ready");
    },
  };

  function menu(items) {
    return {
      items,
      isOpen: false,
      actor: {
        mapped: false,
        height: 100,
        get_transformed_position: () => [10, 10],
        get_transformed_size() {
          return [200, this.height];
        },
        get_preferred_height() {
          return [0, this.height];
        },
        get_theme_node: () => ({ get_max_height: () => 1400 }),
      },
      _getMenuItems() {
        return this.items;
      },
      open() {
        if (this.isOpen) return;
        this.isOpen = true;
        this.actor.mapped = true;
        this.openedFrame = helper.frames;
      },
      close() {
        this.isOpen = false;
        this.actor.mapped = false;
      },
    };
  }
}

function entry(id, label, menu, icon = null) {
  return {
    _dbusItem: { getId: () => id },
    label: { text: label },
    _icon: { gicon: icon },
    menu,
  };
}
