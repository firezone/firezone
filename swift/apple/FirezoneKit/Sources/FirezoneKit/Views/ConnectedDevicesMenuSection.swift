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

  /// Submenu content of a device pool, listing its connected devices.
  struct DevicePoolSubmenu: View {
    let devices: [ConnectedDevice]

    var body: some View {
      if devices.isEmpty {
        Text("No connected devices")
          .foregroundStyle(.secondary)
      } else {
        let visible = devices.prefix(maxDevicesInline)
        ForEach(visible) { device in
          ConnectedDeviceMenuItem(device: device)
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

  /// A single connected device, labelled by slug, with details in a submenu.
  struct ConnectedDeviceMenuItem: View {
    let device: ConnectedDevice

    var body: some View {
      Menu(device.slug) {
        ConnectedDeviceDetailsSubmenu(device: device)
      }
    }
  }

  /// Copyable details for a connected device: domain, tunnel IPs and client details.
  struct ConnectedDeviceDetailsSubmenu: View {
    let device: ConnectedDevice

    var body: some View {
      Group {
        Text("Device")
          .foregroundStyle(.secondary)
        Button(device.domain) {
          Clipboard.copy(device.domain)
        }

        Divider()

        Text("Tunnel IPs")
          .foregroundStyle(.secondary)
        Button(device.tunIPv4) {
          Clipboard.copy(device.tunIPv4)
        }
        Button(device.tunIPv6) {
          Clipboard.copy(device.tunIPv6)
        }

        Divider()

        Text("Client Details")
          .foregroundStyle(.secondary)
        Button(device.id) {
          Clipboard.copy(device.id)
        }
        Button(device.name) {
          Clipboard.copy(device.name)
        }
      }
    }
  }
#endif
