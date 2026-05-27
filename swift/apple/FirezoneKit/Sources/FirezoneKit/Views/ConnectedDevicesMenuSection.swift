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

  /// "Devices (N)" submenu listing the peer devices this client is connected to.
  /// Renders nothing when there are no connected peers.
  struct ConnectedDevicesSection: View {
    @EnvironmentObject var store: Store

    var body: some View {
      if !store.connectedDevices.isEmpty {
        Menu("Devices (\(store.connectedDevices.count))") {
          let visible = store.connectedDevices.prefix(maxDevicesInline)
          ForEach(visible) { device in
            ConnectedDeviceMenuItem(device: device)
          }

          let hidden = store.connectedDevices.count - visible.count
          if hidden > 0 {
            Divider()
            Text(hidden == 1 ? "And 1 more device…" : "And \(hidden) more devices…")
              .foregroundStyle(.secondary)
          }
        }
      }
    }
  }

  /// A single connected device, labelled by its tunnel IPv4, with details in a submenu.
  struct ConnectedDeviceMenuItem: View {
    let device: ConnectedDevice

    var body: some View {
      Menu(device.tunneledIPv4) {
        ConnectedDeviceDetailsSubmenu(device: device)
      }
    }
  }

  /// Copyable details for a connected device: tunnel IPv4, client ID, and pools.
  struct ConnectedDeviceDetailsSubmenu: View {
    let device: ConnectedDevice

    var body: some View {
      Group {
        Text("Tunnel IPv4")
          .foregroundStyle(.secondary)
        Button(device.tunneledIPv4) {
          copyToClipboard(device.tunneledIPv4)
        }

        Divider()

        Text("Client ID")
          .foregroundStyle(.secondary)
        Button(device.id) {
          copyToClipboard(device.id)
        }

        if !device.pools.isEmpty {
          Divider()

          Text(device.pools.count == 1 ? "Pool" : "Pools")
            .foregroundStyle(.secondary)
          ForEach(device.pools, id: \.self) { pool in
            Button(pool) {
              copyToClipboard(pool)
            }
          }
        }
      }
    }

    func copyToClipboard(_ string: String) {
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.setString(string, forType: .string)
    }
  }
#endif
