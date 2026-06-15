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
        // Information: the description or address, and the Site status. The
        // parent menu item already shows the name, so it isn't repeated here.
        if resource.isInternetResource() {
          Text("All network traffic")
            .foregroundStyle(.secondary)
        } else if let detail = displayDetail {
          if let url = URL(string: detail), url.scheme != nil {
            Link(destination: url) {
              Text(detail)
                .foregroundColor(.blue)
                .underline()
            }
          } else {
            Text(detail)
              .foregroundStyle(.secondary)
          }
        }

        if let site = resource.sites.first {
          siteStatus(site)
        }

        // Actions, separated from the information above.
        if hasInfo {
          Divider()
        }

        if resource.isInternetResource() {
          Button(internetResourceToggleTitle) {
            store.configuration.internetResourceEnabled.toggle()
          }
        } else {
          if let address = resource.address {
            Button("Copy address") {
              Clipboard.copy(address)
            }
          }

          Button(favoriteToggleTitle) {
            toggleFavorite()
          }
        }
      }
    }

    /// The single detail line: the description if present, otherwise the
    /// address. Hidden when empty or identical to the name shown by the parent.
    private var displayDetail: String? {
      let description = resource.addressDescription.flatMap { $0.isEmpty ? nil : $0 }
      guard let detail = description ?? resource.address,
        !detail.isEmpty,
        detail != resource.name
      else { return nil }

      return detail
    }

    private var hasInfo: Bool {
      resource.isInternetResource() || displayDetail != nil || resource.sites.first != nil
    }

    /// The Site name with its status as a colored dot. The textual status is
    /// kept in the tooltip so the menu stays compact.
    @ViewBuilder
    private func siteStatus(_ site: Site) -> some View {
      Button {
        Clipboard.copy(site.name)
      } label: {
        HStack {
          if let icon = resource.status.statusIcon {
            Image(nsImage: icon)
          }
          Text(site.name)
        }
      }
      .help(resource.status.toSiteStatusTooltip())
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

  /// Main resources section showing favorites and other resources
  struct ResourcesSection: View {
    @EnvironmentObject var store: Store

    /// Partitioned resources for display.
    /// If no resources are favorited, all resources show directly in the menu.
    /// Otherwise, favorites show directly and others go in the "Other Resources" submenu.
    private var partitionedResources:
      (
        internetResource: Resource?,
        directlyShown: [Resource],
        others: [Resource]
      )
    {
      let allResources = store.resourceList.asArray()

      // Check if user has favorited anything (excluding internet resource)
      let hasAnyFavorites = allResources.contains {
        !$0.isInternetResource() && store.favorites.contains($0.id)
      }

      return allResources.reduce(
        into: (internetResource: nil, directlyShown: [], others: [])
      ) { result, resource in
        if resource.isInternetResource() {
          result.internetResource = resource
        } else if !hasAnyFavorites {
          // No favorites: show all resources directly
          result.directlyShown.append(resource)
        } else if store.favorites.contains(resource.id) {
          // Has favorites: show only favorites directly
          result.directlyShown.append(resource)
        } else {
          // Has favorites: non-favorites go to submenu
          result.others.append(resource)
        }
      }
    }

    var body: some View {
      let resources = partitionedResources

      Group {
        // Header text
        Text(resourcesHeaderText)
          .foregroundStyle(.secondary)

        // Internet resource (always first if present)
        if let internet = resources.internetResource {
          ResourceMenuItem(resource: internet)
        }

        // Directly shown resources (favorites, or all if no favorites)
        ForEach(resources.directlyShown) { resource in
          ResourceMenuItem(resource: resource)
        }

        // Other Resources submenu (only when favorites exist and there are non-favorites)
        if !resources.others.isEmpty {
          Menu("Other Resources") {
            ForEach(resources.others) { resource in
              ResourceMenuItem(resource: resource)
            }
          }
        }
      }
    }

    var resourcesHeaderText: String {
      switch store.resourceList {
      case .loading:
        return "Loading Resources..."
      case .loaded(let list):
        return list.isEmpty ? "No Resources" : "Resources"
      }
    }
  }
#endif
