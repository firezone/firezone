//
//  ResourceMenuSection.swift
//  (c) 2025 Firezone, Inc.
//  LICENSE: Apache-2.0
//

#if os(macOS)
  import SwiftUI

  /// Individual resource menu item with submenu containing resource details
  struct ResourceMenuItem: View {
    let resource: Resource
    @EnvironmentObject var store: Store

    var body: some View {
      Menu(resourceTitle) {
        ResourceDetailsSubmenu(resource: resource)
      }
    }

    var resourceTitle: String {
      if resource.isInternetResource() {
        let status =
          store.configuration.internetResourceEnabled
          ? StatusSymbol.enabled
          : StatusSymbol.disabled
        return "\(status) \(resource.name)"
      }
      return resource.name
    }
  }

  /// Submenu containing resource details and actions
  struct ResourceDetailsSubmenu: View {
    let resource: Resource
    @EnvironmentObject var store: Store

    var body: some View {
      Group {
        if resource.isDevicePool() {
          DevicePoolSubmenu(devices: resource.devices)
        } else if resource.isInternetResource() {
          Text("All network traffic")
            .foregroundStyle(.secondary)

          Divider()

          Button(internetResourceToggleTitle) {
            store.configuration.internetResourceEnabled.toggle()
          }
        } else {
          if let description = resource.addressDescription {
            if let url = resource.descriptionURL {
              Link(destination: url) {
                Text(description)
                  .foregroundColor(.blue)
                  .underline()
              }
            } else {
              Button(description) {
                Clipboard.copy(description)
              }
            }
          }

          if let address = resource.address {
            Button(address) {
              Clipboard.copy(address)
            }
          }
        }
      }
    }

    var internetResourceToggleTitle: String {
      store.configuration.internetResourceEnabled ? "Disable this resource" : "Enable this resource"
    }
  }

  /// The Internet Resource and the favorites, then the item that opens the Resources window,
  /// which leads the items below it.
  struct ResourcesSection: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) private var openWindow

    var body: some View {
      let sections = ResourceSections(store.resourceList.asArray(), favorites: store.favorites)

      Group {
        if !sections.favorites.isEmpty {
          Text("Favorite Resources")
            .foregroundStyle(.secondary)
        }

        if let internet = sections.internet {
          ResourceMenuItem(resource: internet)
        }

        ForEach(sections.favorites) { resource in
          ResourceMenuItem(resource: resource)
        }

        if sections.internet != nil || !sections.favorites.isEmpty {
          Divider()
        }

        Button("Resources") {
          openWindow(id: ResourcesView.windowID)
          // A menu bar app is not active while its menu is used.
          NSApp.activate(ignoringOtherApps: true)
        }
      }
    }
  }
#endif
