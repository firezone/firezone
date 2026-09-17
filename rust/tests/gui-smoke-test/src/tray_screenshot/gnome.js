global.firezoneScreenshot = {
  prepare(resource, stylesheet) {
    this.theme = Gio.Resource.load(resource);
    this.theme._register();
    Main.setThemeStylesheet(stylesheet);
    Main.loadTheme();
    Main.overview.hide();
    Main.welcomeDialog?.close();
    this.frames = 0;
    global.stage.connect("after-paint", () => this.frames++);
    this.checkpoints = new Map();
    this.refreshes = 0;
    return true;
  },

  open(label) {
    const indicator = Object.values(Main.panel.statusArea).find(
      (item) => item?._indicator?.id === "dev.firezone.client"
    );
    const client = indicator?._menuClient?._client;
    if (!client) return false;

    global.get_window_actors().forEach((actor) => actor.meta_window.minimize());
    // An empty PopupMenu cannot open to activate deferred DBusMenu updates.
    client.active = true;
    this.readLayout(client);
    const actual = this.describeMenu(indicator.menu);
    const expected = this.layout?.children;
    const complete =
      !this.readError &&
      expected?.some((item) => item.label === label) &&
      JSON.stringify(actual) === JSON.stringify(expected);
    const progress = JSON.stringify({
      actual,
      expected,
      readError: this.readError,
    });
    const now = GLib.get_monotonic_time();
    if (this.progress !== progress) {
      this.progress = progress;
      this.progressAt = now;
    }
    if (!complete) {
      this.checkpoints.clear();
      if (now - this.progressAt >= 5_000_000) {
        if (this.refreshes >= 3)
          throw new Error("AppIndicator menu is stale after three refreshes");
        // AppIndicator can lose a deferred layout update while fetching an older
        // layout. Refresh properties too: existing IDs may still have no labels.
        client._flagItemsUpdateRequired = true;
        client._requestLayoutUpdate();
        this.refreshes++;
        this.progressAt = now;
        console.log(`Refreshing stale AppIndicator menu (${this.refreshes}/3)`);
      }
      return false;
    }
    if (!this.settled("contents", progress)) return false;

    const resource = indicator.menu
      ._getMenuItems()
      .find((item) => item.label?.text === label);
    if (!resource?.menu) return false;
    this.menu = indicator.menu;
    this.submenu = resource.menu;
    this.menu.open(false);
    if (!this.menu.actor.mapped) return false;
    if (!this.submenu.isOpen) {
      if (!this.settled("root geometry", this.geometry(this.menu)))
        return false;
      this.submenu.open(false);
    }
    const bounds = this.bounds();
    if (!bounds) return false;
    // GNOME chooses the scrollbar policy at open time, so re-open after any
    // content change rather than keeping a decision made from a partial menu.
    if (this.openContents && this.openContents !== progress) {
      this.submenu.close(false);
      this.checkpoints.clear();
      this.openContents = null;
      return false;
    }
    this.openContents = progress;
    return this.settled("expanded geometry", {
      bounds,
      root: this.geometry(this.menu),
      submenu: this.geometry(this.submenu),
    });
  },

  readLayout(client) {
    if (this.reading) return;
    this.reading = true;
    client
      .GetLayoutAsync(0, -1, ["label", "icon-data"])
      .then(([revision, root]) => {
        const describe = ([id, properties, children]) => ({
          id,
          label: (properties.label?.deep_unpack() ?? "").replace(
            /_([^_])/,
            "$1"
          ),
          icon: Boolean(properties["icon-data"]),
          children: children.map((child) => describe(child.deep_unpack())),
        });
        this.layout = describe(root);
        this.revision = revision;
        this.readError = null;
      })
      .catch((error) => {
        this.readError = String(error);
      })
      .finally(() => {
        this.reading = false;
      });
  },

  settled(name, value) {
    const snapshot = JSON.stringify(value);
    const previous = this.checkpoints.get(name);
    if (previous?.snapshot !== snapshot) {
      this.checkpoints.set(name, { snapshot, frame: this.frames });
      global.stage.queue_redraw();
      return false;
    }
    if (this.frames - previous.frame < 2) {
      global.stage.queue_redraw();
      return false;
    }
    return true;
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

  geometry(menu) {
    if (!menu) return null;
    return {
      position: menu.actor.get_transformed_position(),
      size: menu.actor.get_transformed_size(),
      naturalHeight: menu.actor.get_preferred_height(-1)[1],
      maxHeight: menu.actor.get_theme_node().get_max_height(),
      scrollbarPolicy: menu.actor.vscrollbar_policy,
      scrollbarVisible: menu.actor.vscrollbar_visible,
    };
  },

  describeMenu(menu) {
    return (
      menu?._getMenuItems().map((item) => ({
        id: item._dbusItem?.getId(),
        label: item.label?.text ?? "",
        icon: Boolean(item._icon?.gicon),
        children: this.describeMenu(item.menu),
      })) ?? []
    );
  },

  describe() {
    return {
      revision: this.revision,
      expected: this.layout,
      readError: this.readError,
      refreshes: this.refreshes,
      rootGeometry: this.geometry(this.menu),
      submenuGeometry: this.geometry(this.submenu),
      panel: Object.entries(Main.panel.statusArea)
        .filter(([name]) => name.startsWith("appindicator-"))
        .map(([name, item]) => {
          const client = item?._menuClient?._client;
          return {
            name,
            id: item?._indicator?.id,
            ready: item?._menuClient?.isReady,
            layoutPending: client?._flagLayoutUpdateRequired,
            propertiesPending: client?._flagItemsUpdateRequired,
            layoutInFlight: Boolean(client?._layoutUpdateCancellable),
            propertiesRequested: [...(client?._propertiesRequestedFor ?? [])],
            itemsBeingAdded: [
              ...(item?._menuClient?._itemsBeingAdded ?? []),
            ].map((child) => child.getId()),
            menu: this.describeMenu(item?.menu),
          };
        }),
      extensions: Main.extensionManager.getUuids().map((uuid) => {
        const extension = Main.extensionManager.lookup(uuid);
        return { uuid, state: extension.state, errors: extension.errors };
      }),
    };
  },
};
true;
