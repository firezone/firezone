//
//  ConnectedDevicesMenuSection.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

#if os(macOS)
  import SwiftUI

  /// Maximum number of connected devices listed inline before collapsing the rest
  /// into an "And N more…" row. Mirrors the desktop client's tray (`MAX_DEVICES_INLINE`).
  private let maxDevicesInline = 20

  /// Submenu content of a device pool: the hostname of each connected device, copied on click.
  struct DevicePoolSubmenu: View {
    let devices: [ConnectedDevice]

    var body: some View {
      if devices.isEmpty {
        Text("No connected devices")
          .foregroundStyle(.secondary)
      } else {
        let visible = devices.prefix(maxDevicesInline)
        ForEach(visible) { device in
          Button(device.domain) {
            Clipboard.copy(device.domain)
          }
        }

        let hidden = devices.count - visible.count
        if hidden > 0 {
          Divider()
          Text(hidden == 1 ? "And 1 more device…" : "And \(hidden) more devices…")
            .foregroundStyle(.secondary)
        }
      }
    }
  }
#endif
