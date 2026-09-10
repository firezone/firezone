global.firezoneScreenshot = {
  prepare(resource, stylesheet) {
    this.theme = Gio.Resource.load(resource);
    this.theme._register();
    Main.setThemeStylesheet(stylesheet);
    Main.loadTheme();
    Main.overview.hide();
    Main.welcomeDialog?.close();
    return true;
  },

  open(label) {
    const indicator = Object.values(Main.panel.statusArea).find(
      (item) => item?._indicator?.id === "dev.firezone.client"
    );
    if (!indicator) return false;

    global.get_window_actors().forEach((actor) => actor.meta_window.minimize());
    // An empty PopupMenu cannot open to activate deferred DBusMenu updates.
    if (indicator._menuClient) indicator._menuClient._client.active = true;
    indicator.menu.open(false);
    const resource = indicator.menu
      ._getMenuItems()
      .find((item) => item.label?.text === label);
    if (!resource?.menu) return false;
    resource.menu.open(false);
    this.menu = indicator.menu;
    this.submenu = resource.menu;
    return resource.menu._getMenuItems().some((item) => item.label?.text);
  },

  bounds() {
    const menus = [this.menu, this.submenu];
    if (menus.some((menu) => !menu?.isOpen || !menu.actor.mapped)) return null;
    const rects = menus.map((menu) => {
      const [x, y] = menu.actor.get_transformed_position();
      const [width, height] = menu.actor.get_transformed_size();
      return [x, y, x + width, y + height];
    });
    const x = Math.floor(Math.min(...rects.map((rect) => rect[0])));
    const y = Math.floor(Math.min(...rects.map((rect) => rect[1])));
    const right = Math.ceil(Math.max(...rects.map((rect) => rect[2])));
    const bottom = Math.ceil(Math.max(...rects.map((rect) => rect[3])));
    return [x, y, right - x, bottom - y];
  },

  describe() {
    const describeMenu = (menu) =>
      menu?._getMenuItems().map((item) => ({
        label: item.label?.text,
        visible: item.visible,
        children: item.menu ? describeMenu(item.menu) : undefined,
      }));
    return {
      panel: Object.entries(Main.panel.statusArea)
        .filter(([name]) => name.startsWith("appindicator-"))
        .map(([name, item]) => ({
          name,
          id: item?._indicator?.id,
          ready: item?._menuClient?.isReady,
          menu: describeMenu(item?.menu),
        })),
      extensions: Main.extensionManager.getUuids().map((uuid) => {
        const extension = Main.extensionManager.lookup(uuid);
        return { uuid, state: extension.state, errors: extension.errors };
      }),
    };
  },
};
true;
