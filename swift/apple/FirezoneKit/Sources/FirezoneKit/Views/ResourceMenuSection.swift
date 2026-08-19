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
        // Information: the description or address, and the connection status.
        // The parent menu item already shows the name, so it isn't repeated
        // here.
        if resource.isInternetResource() {
          Text("All network traffic")
            .foregroundStyle(.secondary)
        } else if let link = descriptionLink {
          Link(destination: link.url) {
            Text(link.text)
              .foregroundColor(.blue)
              .underline()
          }
        } else if let detail = displayDetail {
          Text(detail)
            .foregroundStyle(.secondary)
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
          if let address = resource.address, !address.isEmpty {
            Button("Copy address") {
              Clipboard.copy(address)
            }
          }

          // A checkable item, ticked while the Resource is a favorite, like
          // on Windows and Linux.
          Toggle(favoriteToggleTitle, isOn: isFavorite)
        }
      }
    }

    /// The description as a clickable link. Always shown — even when equal to
    /// the name — because the parent menu item is not clickable, making this
    /// link the only way to open it.
    private var descriptionLink: (text: String, url: URL)? {
      guard let description = resource.addressDescription,
        let url = URL(string: description),
        url.scheme != nil
      else { return nil }

      return (description, url)
    }

    /// The single non-link detail line: the description if present, otherwise
    /// the address. Hidden when empty or identical to the name shown by the
    /// parent.
    private var displayDetail: String? {
      let description = resource.addressDescription.flatMap { $0.isEmpty ? nil : $0 }
      guard let detail = description ?? resource.address,
        !detail.isEmpty,
        detail != resource.name
      else { return nil }

      return detail
    }

    private var hasInfo: Bool {
      resource.isInternetResource() || descriptionLink != nil || displayDetail != nil
        || resource.sites.first != nil
    }

    /// The connection status as a single line: a colored dot plus a short
    /// label, with the Site name included when connected. The longer textual
    /// explanation is kept in the tooltip so the menu stays compact.
    @ViewBuilder
    private func siteStatus(_ site: Site) -> some View {
      HStack {
        if let icon = resource.status.statusIcon {
          Image(nsImage: icon)
        }
        Text(statusTitle(site))
          .foregroundStyle(.secondary)
      }
      .help(resource.status.toSiteStatusTooltip())
    }

    private func statusTitle(_ site: Site) -> String {
      switch resource.status {
      case .online:
        return "Connected: \(site.name)"
      case .unknown:
        return "Unknown"
      case .offline:
        return "Offline"
      }
    }

    var internetResourceToggleTitle: String {
      store.configuration.internetResourceEnabled ? "Disable this resource" : "Enable this resource"
    }

    var favoriteToggleTitle: String {
      store.favorites.contains(resource.id) ? "Remove from favorites" : "Add to favorites"
    }

    private var isFavorite: Binding<Bool> {
      Binding(
        get: { store.favorites.contains(resource.id) },
        set: { isFavorite in
          if isFavorite {
            store.favorites.add(resource.id)
          } else {
            store.favorites.remove(resource.id)
          }
        }
      )
    }
  }

  /// Main resources section showing favorites and other resources
  struct ResourcesSection: View {
    @EnvironmentObject var store: Store

    /// Partitioned resources for display, in the order they were received.
    /// If no resources are favorited, all resources show directly in the menu.
    /// Otherwise, favorites and the Internet Resource show directly and the
    /// rest move to the "Other Resources" submenu.
    private var partitionedResources:
      (
        directlyShown: [Resource],
        others: [Resource],
        hasAnyFavorites: Bool
      )
    {
      let allResources = store.resourceList.asArray()

      // Check if user has favorited anything (excluding internet resource)
      let hasAnyFavorites = allResources.contains {
        !$0.isInternetResource() && store.favorites.contains($0.id)
      }

      guard hasAnyFavorites else {
        // No favorites: show all resources directly
        return (allResources, [], false)
      }

      return (
        allResources.filter { $0.isInternetResource() || store.favorites.contains($0.id) },
        allResources.filter { !$0.isInternetResource() && !store.favorites.contains($0.id) },
        true
      )
    }

    var body: some View {
      let resources = partitionedResources

      Group {
        // Header text
        Text(resourcesHeaderText(hasAnyFavorites: resources.hasAnyFavorites))
          .foregroundStyle(.secondary)

        // Directly shown resources (favorites, or all if no favorites)
        ForEach(resources.directlyShown) { resource in
          ResourceMenuItem(resource: resource)
        }

        // Other Resources submenu (only when there are non-favorites to list)
        if !resources.others.isEmpty {
          Divider()

          Menu("Other Resources") {
            ForEach(resources.others) { resource in
              ResourceMenuItem(resource: resource)
            }
          }
        }
      }
    }

    func resourcesHeaderText(hasAnyFavorites: Bool) -> String {
      switch store.resourceList {
      case .loading:
        return "Loading Resources..."
      case .loaded(let list):
        if list.isEmpty {
          return "No Resources"
        }

        return hasAnyFavorites ? "Favorite Resources" : "Resources"
      }
    }
  }
#endif
