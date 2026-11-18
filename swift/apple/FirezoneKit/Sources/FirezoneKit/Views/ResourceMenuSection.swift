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

  /// Submenu containing resource details, site info, and actions
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
          // Show description, or address if there is none - clickable if it's a valid URL
          if let displayAddress = resource.addressDescription.flatMap({ $0.isEmpty ? nil : $0 })
            ?? resource.address
          {
            if let url = URL(string: displayAddress), url.scheme != nil {
              Link(destination: url) {
                Text(displayAddress)
                  .foregroundColor(.blue)
                  .underline()
              }
            } else {
              Button(displayAddress) {
                Clipboard.copy(displayAddress)
              }
            }
          }

          Divider()

          Text("Resource")
            .foregroundStyle(.secondary)

          if let address = resource.address {
            Button(address) {
              Clipboard.copy(address)
            }

            Button("Copy address") {
              Clipboard.copy(address)
            }
          }

          Button(favoriteToggleTitle) {
            toggleFavorite()
          }
        }

        // Site information (if available)
        if let site = resource.sites.first {
          Divider()

          Text("Site")
            .foregroundStyle(.secondary)

          Button(site.name) {
            Clipboard.copy(site.name)
          }

          Button {
            Clipboard.copy(resource.status.toSiteStatus())
          } label: {
            HStack {
              if let icon = resource.status.statusIcon {
                Image(nsImage: icon)
              }
              Text(resource.status.toSiteStatus())
            }
          }
          .help(resource.status.toSiteStatusTooltip())
        }
      }
    }

    var internetResourceToggleTitle: String {
      store.configuration.internetResourceEnabled ? "Disable this resource" : "Enable this resource"
    }

    var favoriteToggleTitle: String {
      store.favorites.contains(resource.id) ? "Remove from favorites" : "Add to favorites"
    }

    func toggleFavorite() {
      if store.favorites.contains(resource.id) {
        store.favorites.remove(resource.id)
      } else {
        store.favorites.add(resource.id)
      }
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
