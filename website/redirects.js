// Add all server-side redirects here. Will be loaded by next.config.mjs.

module.exports = [
  /*
   *
   * Windows Client
   *
   */
  // latest
  {
    source: "/dl/firezone-client-windows-gui/latest/x86_64",
    destination:
      // mark:automatic-version
      "https://www.github.com/firezone/firezone/releases/download/1.0.0/firezone-client-windows-gui_1.0.0_x86_64.msi",
    permanent: false,
  },
  // versioned
  {
    source: "/dl/firezone-client-windows-gui/:version/x86_64",
    destination:
      "https://www.github.com/firezone/firezone/releases/download/:version/firezone-client-windows-gui_:version_x86_64.msi",
    permanent: false,
  },
  /*
   *
   * Linux Client
   *
   */
  // latest
  {
    source: "/dl/firezone-client-linux-gui/latest/x86_64",
    destination:
      // mark:automatic-version
      "https://www.github.com/firezone/firezone/releases/download/1.0.0/firezone-client-linux-gui_1.0.0_x86_64.deb",
    permanent: false,
  },
  {
    source: "/dl/firezone-client-linux-gui/latest/aarch64",
    destination:
      // mark:automatic-version
      "https://www.github.com/firezone/firezone/releases/download/1.0.0/firezone-client-linux-gui_1.0.0_aarch64.deb",
    permanent: false,
  },
  {
    source: "/dl/firezone-client-linux-headless/latest/x86_64",
    destination:
      // mark:automatic-version
      "https://www.github.com/firezone/firezone/releases/download/1.0.0/firezone-client-linux-headless_1.0.0_x86_64",
    permanent: false,
  },
  {
    source: "/dl/firezone-client-linux-headless/latest/aarch64",
    destination:
      // mark:automatic-version
      "https://www.github.com/firezone/firezone/releases/download/1.0.0/firezone-client-linux-headless_1.0.0_aarch64",
    permanent: false,
  },
  {
    source: "/dl/firezone-client-linux-headless/latest/armv7l",
    destination:
      // mark:automatic-version
      "https://www.github.com/firezone/firezone/releases/download/1.0.0/firezone-client-linux-headless_1.0.0_armv7l",
    permanent: false,
  },
  // versioned
  {
    source: "/dl/firezone-client-linux-gui/:version/x86_64",
    destination:
      "https://www.github.com/firezone/firezone/releases/download/:version/firezone-client-linux-gui_:version_x86_64.deb",
    permanent: false,
  },
  {
    source: "/dl/firezone-client-linux-gui/:version/aarch64",
    destination:
      "https://www.github.com/firezone/firezone/releases/download/:version/firezone-client-linux-gui_:version_aarch64.deb",
    permanent: false,
  },
  {
    source: "/dl/firezone-client-linux-headless/:version/x86_64",
    destination:
      "https://www.github.com/firezone/firezone/releases/download/:version/firezone-client-linux-headless_:version_x86_64",
    permanent: false,
  },
  {
    source: "/dl/firezone-client-linux-headless/:version/aarch64",
    destination:
      "https://www.github.com/firezone/firezone/releases/download/:version/firezone-client-linux-headless_:version_aarch64",
    permanent: false,
  },
  {
    source: "/dl/firezone-client-linux-headless/:version/armv7l",
    destination:
      "https://www.github.com/firezone/firezone/releases/download/:version/firezone-client-linux-headless_:version_armv7l",
    permanent: false,
  },
  /*
   *
   * Gateway
   *
   */
  // latest
  {
    source: "/dl/firezone-gateway/latest/x86_64",
    destination:
      // mark:automatic-version
      "https://www.github.com/firezone/firezone/releases/download/1.0.0/firezone-gateway_1.0.0_x86_64",
    permanent: false,
  },
  {
    source: "/dl/firezone-gateway/latest/aarch64",
    destination:
      // mark:automatic-version
      "https://www.github.com/firezone/firezone/releases/download/1.0.0/firezone-gateway_1.0.0_aarch64",
    permanent: false,
  },
  {
    source: "/dl/firezone-gateway/latest/armv7l",
    destination:
      // mark:automatic-version
      "https://www.github.com/firezone/firezone/releases/download/1.0.0/firezone-gateway_1.0.0_armv7l",
    permanent: false,
  },
  // versioned
  {
    source: "/dl/firezone-gateway/:version/x86_64",
    destination:
      "https://www.github.com/firezone/firezone/releases/download/:version/firezone-gateway_:version_x86_64",
    permanent: false,
  },
  {
    source: "/dl/firezone-gateway/:version/aarch64",
    destination:
      "https://www.github.com/firezone/firezone/releases/download/:version/firezone-gateway_:version_aarch64",
    permanent: false,
  },
  {
    source: "/dl/firezone-gateway/:version/armv7l",
    destination:
      "https://www.github.com/firezone/firezone/releases/download/:version/firezone-gateway_:version_armv7l",
    permanent: false,
  },
];
