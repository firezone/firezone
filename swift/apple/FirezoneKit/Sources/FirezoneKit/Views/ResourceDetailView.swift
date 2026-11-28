//
//  ResourceDetailView.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

#if os(macOS)
  import SwiftUI

  /// The detail pane of the Resources window, which names the Resource in the title bar.
  struct ResourceDetailView: View {
    let resource: Resource
    @EnvironmentObject var store: Store

    var body: some View {
      Form {
        switch resource.type {
        case .dns, .cidr, .ip:
          Section("Resource") {
            CopyableRow(label: "Name", value: resource.name)

            if let address = resource.address {
              CopyableRow(label: "Address", value: address)
            }

            if let description = resource.addressDescription, !description.isEmpty {
              if let url = resource.descriptionURL {
                LabeledContent("Description") {
                  Link(description, destination: url)
                }
              } else {
                CopyableRow(label: "Description", value: description)
              }
            }
          }

          connection

        case .internet:
          Section("Resource") {
            CopyableRow(label: "Name", value: resource.name)
            LabeledContent("Description", value: "All network traffic")
            Toggle("Enabled", isOn: internetResourceEnabled)
          }

          connection

        case .devicePool:
          devices
        }
      }
      .formStyle(.grouped)
      .navigationTitle(resource.name)
      .navigationSubtitle(kind)
      .toolbar {
        if !resource.isInternetResource() {
          ToolbarItem(placement: .primaryAction) {
            Button(action: toggleFavorite) {
              Label(favoriteToggleTitle, systemImage: isFavorite ? "star.fill" : "star")
            }
            .help(favoriteToggleTitle)
          }
        }
      }
    }

    @ViewBuilder
    private var connection: some View {
      if let site = resource.sites.first {
        Section {
          LabeledContent("Status") {
            HStack(spacing: 4) {
              ResourceStatusIcon(status: resource.status)
              Text(resource.status.label)
            }
          }

          CopyableRow(label: "Site", value: site.name)
        } header: {
          Text("Connection")
        } footer: {
          // macOS 15 otherwise pushes the footer to the trailing edge.
          Text(resource.status.explanation)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }

    @ViewBuilder
    private var devices: some View {
      if resource.devices.isEmpty {
        Section("Connected Devices") {
          Text("No connected devices")
            .foregroundStyle(.secondary)
        }
      } else {
        ForEach(resource.devices) { device in
          Section(device.slug) {
            CopyableRow(label: "Hostname", value: device.domain)
            CopyableRow(label: "Tunnel IPv4", value: device.tunIPv4)
            CopyableRow(label: "Tunnel IPv6", value: device.tunIPv6)
            CopyableRow(label: "Client Name", value: device.name)
            CopyableRow(label: "Client ID", value: device.id)
          }
        }
      }
    }

    private var kind: String {
      switch resource.type {
      case .dns: return "DNS Resource"
      case .cidr: return "CIDR Resource"
      case .ip: return "IP Resource"
      case .devicePool: return "Device Pool"
      // connlib names every Internet Resource exactly that.
      case .internet: return ""
      }
    }

    private var internetResourceEnabled: Binding<Bool> {
      Binding(
        get: { store.configuration.internetResourceEnabled },
        set: { store.configuration.internetResourceEnabled = $0 }
      )
    }

    private var isFavorite: Bool { store.favorites.contains(resource.id) }

    private var favoriteToggleTitle: String {
      isFavorite ? "Remove from Favorites" : "Add to Favorites"
    }

    private func toggleFavorite() {
      if isFavorite {
        store.favorites.remove(resource.id)
      } else {
        store.favorites.add(resource.id)
      }
    }
  }

  /// A form row whose value can be selected, or copied whole with the button beside it.
  private struct CopyableRow: View {
    let label: String
    let value: String

    var body: some View {
      LabeledContent(label) {
        HStack(spacing: 4) {
          Text(value)
            .textSelection(.enabled)

          ButtonWithProgress(
            systemImageName: "doc.on.doc",
            title: "Copy \(label)",
            isProcessing: false,
            action: { Clipboard.copy(value) }
          )
        }
      }
    }
  }
#endif
