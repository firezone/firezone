//
//  ConnectedDevicesSection.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

// iOS counterpart of the macOS menu's connected-devices submenu
// (see ConnectedDevicesMenuSection.swift). Renders as a list section inside SessionView.

#if os(iOS)
  import SwiftUI

  /// "Connected Devices (N)" section listing the peer devices this client is connected to.
  /// Renders nothing when there are no connected peers.
  struct ConnectedDevicesSection: View {
    @EnvironmentObject var store: Store

    var body: some View {
      if !store.connectedDevices.isEmpty {
        Section("Connected Devices (\(store.connectedDevices.count))") {
          ForEach(store.connectedDevices) { device in
            NavigationLink {
              ConnectedDeviceView(device: device)
            } label: {
              Text(device.tunIPv4)
            }
          }
        }
      }
    }
  }

  /// Detail screen for a connected device: tunnel IPv4, client ID, and pools,
  /// each copyable via a long-press context menu.
  struct ConnectedDeviceView: View {
    let device: ConnectedDevice

    var body: some View {
      List {
        Section(header: Text("Tunnel IPv4")) {
          copyableRow(device.tunIPv4)
        }

        Section(header: Text("Tunnel IPv6")) {
          copyableRow(device.tunIPv6)
        }

        Section(header: Text("Client ID")) {
          copyableRow(device.id)
        }

        if !device.pools.isEmpty {
          Section(header: Text(device.pools.count == 1 ? "Pool" : "Pools")) {
            ForEach(device.pools, id: \.self) { pool in
              copyableRow(pool)
            }
          }
        }
      }
      .listStyle(GroupedListStyle())
      .navigationBarTitle("Details", displayMode: .inline)
    }

    @ViewBuilder
    private func copyableRow(_ value: String) -> some View {
      Text(value)
        .contextMenu {
          Button(
            action: { Clipboard.copy(value) },
            label: {
              Text("Copy")
              Image(systemName: "doc.on.doc")
            }
          )
        }
    }
  }
#endif
