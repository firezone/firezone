//
//  ConnectedDevicesSection.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

// iOS counterpart of the macOS menu's device pool submenu
// (see ConnectedDevicesMenuSection.swift). Renders as a list section inside ResourceView.

#if os(iOS)
  import SwiftUI

  /// Section listing the connected devices of a device pool.
  struct ConnectedDevicesSection: View {
    let devices: [ConnectedDevice]

    var body: some View {
      Section(header: Text("Devices")) {
        if devices.isEmpty {
          Text("No connected devices")
            .foregroundColor(.secondary)
        } else {
          ForEach(devices) { device in
            NavigationLink(value: device) {
              Text(device.name)
            }
          }
        }
      }
    }
  }

  /// Detail screen for a connected device: tunnel IPs and client details,
  /// each copyable via a long-press context menu.
  struct ConnectedDeviceView: View {
    let device: ConnectedDevice

    var body: some View {
      List {
        Section(header: Text("Tunnel IPs")) {
          copyableRow(device.tunIPv4)
          copyableRow(device.tunIPv6)
        }

        Section(header: Text("Client Details")) {
          copyableRow(device.id)
          copyableRow(device.name)
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
