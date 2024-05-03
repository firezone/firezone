// Add all server-side redirects here. Will be loaded by next.config.mjs.

module.exports = [
  /*
   *
   * Windows Client
   *
   */
  // latest
  {
    source: "/dl/firezone-client-gui-windows/latest/x86_64",
    destination:
      // mark:automatic-version
      "https://www.github.com/firezone/firezone/releases/download/1.0.2/firezone-client-gui-windows_1.0.2_x86_64.msi",
    permanent: false,
  },
  // versioned
  {
    source: "/dl/firezone-client-gui-windows/:version/x86_64",
    destination:
      "https://www.github.com/firezone/firezone/releases/download/:version/firezone-client-gui-windows_:version_x86_64.msi",
    permanent: false,
  },
  /*
   *
   * Linux Client
   *
   */
  // latest
  {
    source: "/dl/firezone-client-gui-linux/latest/x86_64",
    destination:
      // mark:automatic-version
      "https://www.github.com/firezone/firezone/releases/download/1.0.2/firezone-client-gui-linux_1.0.2_x86_64.deb",
    permanent: false,
  },
  {
    source: "/dl/firezone-client-gui-linux/latest/aarch64",
    destination:
      // mark:automatic-version
      "https://www.github.com/firezone/firezone/releases/download/1.0.2/firezone-client-gui-linux_1.0.2_aarch64.deb",
    permanent: false,
  },
  {
    source: "/dl/firezone-client-headless-linux/latest/x86_64",
    destination:
      // mark:automatic-version
      "https://www.github.com/firezone/firezone/releases/download/1.0.2/firezone-client-headless-linux_1.0.2_x86_64",
    permanent: false,
  },
  {
    source: "/dl/firezone-client-headless-linux/latest/aarch64",
    destination:
      // mark:automatic-version
      "https://www.github.com/firezone/firezone/releases/download/1.0.2/firezone-client-headless-linux_1.0.2_aarch64",
    permanent: false,
  },
  {
    source: "/dl/firezone-client-headless-linux/latest/armv7",
    destination:
      // mark:automatic-version
      "https://www.github.com/firezone/firezone/releases/download/1.0.2/firezone-client-headless-linux_1.0.2_armv7",
    permanent: false,
  },
  // versioned
  {
    source: "/dl/firezone-client-gui-linux/:version/x86_64",
    destination:
      "https://www.github.com/firezone/firezone/releases/download/:version/firezone-client-gui-linux_:version_x86_64.deb",
    permanent: false,
  },
  {
    source: "/dl/firezone-client-gui-linux/:version/aarch64",
    destination:
      "https://www.github.com/firezone/firezone/releases/download/:version/firezone-client-gui-linux_:version_aarch64.deb",
    permanent: false,
  },
  {
    source: "/dl/firezone-client-headless-linux/:version/x86_64",
    destination:
      "https://www.github.com/firezone/firezone/releases/download/:version/firezone-client-headless-linux_:version_x86_64",
    permanent: false,
  },
  {
    source: "/dl/firezone-client-headless-linux/:version/aarch64",
    destination:
      "https://www.github.com/firezone/firezone/releases/download/:version/firezone-client-headless-linux_:version_aarch64",
    permanent: false,
  },
  {
    source: "/dl/firezone-client-headless-linux/:version/armv7",
    destination:
      "https://www.github.com/firezone/firezone/releases/download/:version/firezone-client-headless-linux_:version_armv7",
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
      "https://www.github.com/firezone/firezone/releases/download/1.0.2/firezone-gateway_1.0.2_x86_64",
    permanent: false,
  },
  {
    source: "/dl/firezone-gateway/latest/aarch64",
    destination:
      // mark:automatic-version
      "https://www.github.com/firezone/firezone/releases/download/1.0.2/firezone-gateway_1.0.2_aarch64",
    permanent: false,
  },
  {
    source: "/dl/firezone-gateway/latest/armv7",
    destination:
      // mark:automatic-version
      "https://www.github.com/firezone/firezone/releases/download/1.0.2/firezone-gateway_1.0.2_armv7",
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
    source: "/dl/firezone-gateway/:version/armv7",
    destination:
      "https://www.github.com/firezone/firezone/releases/download/:version/firezone-gateway_:version_armv7",
    permanent: false,
  },
];
