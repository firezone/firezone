// Add all server-side redirects here. Will be loaded by next.config.mjs.

module.exports = [
  /*
   *
   * macOS Client
   *
   */
  {
    source: "/dl/firezone-client-macos/latest",
    destination:
      // mark:current-apple-version
      "https://www.github.com/firezone/firezone/releases/download/macos-client-1.5.10/firezone-macos-client-1.5.10.dmg",
    permanent: false,
  },
  {
    source: "/dl/firezone-client-macos/pkg/latest",
    destination:
      // mark:current-apple-version
      "https://www.github.com/firezone/firezone/releases/download/macos-client-1.5.10/firezone-macos-client-1.5.10.pkg",
    permanent: false,
  },
  /*
   *
   * Android Client
   *
   */
  {
    source: "/dl/firezone-client-android/latest",
    destination:
      // mark:current-android-version
      "https://www.github.com/firezone/firezone/releases/download/android-client-1.5.7/firezone-android-client-1.5.7.apk",
    permanent: false,
  },
  /*
   *
   * Windows GUI Client
   *
   */
  {
    source: "/dl/firezone-client-gui-windows/latest/x86_64",
    destination:
      // mark:current-gui-version
      "https://www.github.com/firezone/firezone/releases/download/gui-client-1.5.8/firezone-client-gui-windows_1.5.8_x86_64.msi",
    permanent: false,
  },
  /*
   *
   * Windows Headless Client
   *
   */
  {
    source: "/dl/firezone-client-headless-windows/latest/x86_64",
    destination:
      // mark:current-headless-version
      "https://www.github.com/firezone/firezone/releases/download/headless-client-1.5.4/firezone-client-headless-windows_1.5.4_x86_64.exe",
    permanent: false,
  },
  /*
   *
   * Linux Clients
   *
   */
  {
    source: "/dl/firezone-client-gui-linux/latest/x86_64",
    destination:
      // mark:current-gui-version
      "https://www.github.com/firezone/firezone/releases/download/gui-client-1.5.8/firezone-client-gui-linux_1.5.8_x86_64.deb",
    permanent: false,
  },
  {
    source: "/dl/firezone-client-gui-linux/latest/aarch64",
    destination:
      // mark:current-gui-version
      "https://www.github.com/firezone/firezone/releases/download/gui-client-1.5.8/firezone-client-gui-linux_1.5.8_aarch64.deb",
    permanent: false,
  },
  {
    source: "/dl/firezone-client-headless-linux/latest/x86_64",
    destination:
      // mark:current-headless-version
      "https://www.github.com/firezone/firezone/releases/download/headless-client-1.5.4/firezone-client-headless-linux_1.5.4_x86_64",
    permanent: false,
  },
  {
    source: "/dl/firezone-client-headless-linux/latest/aarch64",
    destination:
      // mark:current-headless-version
      "https://www.github.com/firezone/firezone/releases/download/headless-client-1.5.4/firezone-client-headless-linux_1.5.4_aarch64",
    permanent: false,
  },
  {
    source: "/dl/firezone-client-headless-linux/latest/armv7",
    destination:
      // mark:current-headless-version
      "https://www.github.com/firezone/firezone/releases/download/headless-client-1.5.4/firezone-client-headless-linux_1.5.4_armv7",
    permanent: false,
  },
  /*
   *
   * Gateway
   *
   */
  {
    source: "/dl/firezone-gateway/latest/x86_64",
    destination:
      // mark:current-gateway-version
      "https://www.github.com/firezone/firezone/releases/download/gateway-1.4.18/firezone-gateway_1.4.18_x86_64",
    permanent: false,
  },
  {
    source: "/dl/firezone-gateway/latest/aarch64",
    destination:
      // mark:current-gateway-version
      "https://www.github.com/firezone/firezone/releases/download/gateway-1.4.18/firezone-gateway_1.4.18_aarch64",
    permanent: false,
  },
  {
    source: "/dl/firezone-gateway/latest/armv7",
    destination:
      // mark:current-gateway-version
      "https://www.github.com/firezone/firezone/releases/download/gateway-1.4.18/firezone-gateway_1.4.18_armv7",
    permanent: false,
  },
  /*
   * Redirects for old Website URLs. Most search engines should have re-indexed these after 1 year.
   * However, other sites may have not, so the general rule here is to keep them indefinitely unless
   * we need to reuse a particular URL.
   *
   * See https://ahrefs.com/blog/are-pemanent-redirects-permanent
   *
   */
  {
    source: "/kb/user-guides/:path",
    destination: "/kb/client-apps/:path",
    permanent: true,
  },
  {
    source: "/kb/user-guides",
    destination: "/kb/client-apps",
    permanent: true,
  },
  {
    source: "/kb/client-apps/windows-client",
    destination: "/kb/client-apps/windows-gui-client",
    permanent: true,
  },
  {
    source: "/kb/client-apps/linux-client",
    destination: "/kb/client-apps/linux-headless-client",
    permanent: true,
  },
  {
    source: "/docs/:path*",
    destination: "/kb",
    permanent: true,
  },
  {
    source: "/kb/authenticate/directory-sync",
    destination: "/kb/directory-sync",
    permanent: true,
  },
];
