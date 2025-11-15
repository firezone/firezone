//
//  ResourceMenuSection.swift
//  (c) 2025 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import SwiftUI

/// Individual resource menu item with submenu containing resource details
struct ResourceMenuItem: View {
  let resource: Resource
  @EnvironmentObject var store: Store

  var body: some View {
    Menu {
      ResourceDetailsSubmenu(resource: resource)
    } label: {
      HStack(spacing: 4) {
        if let symbolName = resourceSymbol {
          Image(systemName: symbolName)
        }
        Text(resource.name)
      }
    }
  }

  var resourceSymbol: String? {
    if resource.isInternetResource() {
      return store.configuration.internetResourceEnabled ? "network" : "network.slash"
    }
    // For regular resources, show status indicator
    switch resource.status {
    case .online:
      return "checkmark.circle.fill"
    case .offline:
      return "xmark.circle.fill"
    case .unknown:
      return "circle"
    }
  }
}

/// Submenu containing resource details, site info, and actions
struct ResourceDetailsSubmenu: View {
  let resource: Resource
  @EnvironmentObject var store: Store

  var body: some View {
    Group {
      // Address or description header
      if resource.isInternetResource() {
        Text("All network traffic")
          .foregroundStyle(.secondary)

        Divider()

        Button(internetResourceToggleTitle) {
          store.configuration.internetResourceEnabled.toggle()
        }
      } else {
        // Show addressDescription if available, otherwise address
        if let addressDescription = resource.addressDescription {
          if let url = URL(string: addressDescription), url.host != nil {
            Button {
              Task { await NSWorkspace.shared.openAsync(url) }
            } label: {
              HStack {
                Text(addressDescription)
                Spacer()
                Image(systemName: "arrow.up.forward")
              }
            }
          } else {
            Button(addressDescription) {
              copyToClipboard(addressDescription)
            }
          }
        } else if let address = resource.address {
          Button(address) {
            copyToClipboard(address)
          }
        }

        Divider()

        Text("Resource")
          .foregroundStyle(.secondary)

        Menu("Actions") {
          // Open in browser if address is a URL
          if let url = resourceURL {
            Button {
              Task { await NSWorkspace.shared.openAsync(url) }
            } label: {
              HStack {
                Text("Open in browser")
                Spacer()
                Image(systemName: "arrow.up.forward")
              }
            }
          }

          Button("Copy name") {
            copyToClipboard(resource.name)
          }

          if let address = resource.address {
            Button("Copy address") {
              copyToClipboard(address)
            }
          }

          Button(favoriteToggleTitle) {
            toggleFavorite()
          }
        }
      }

      // Site information (if available)
      if let site = resource.sites.first {
        Divider()

        Text("Site")
          .foregroundStyle(.secondary)

        Button(site.name) {
          copyToClipboard(site.name)
        }

        Button(siteStatusWithEmoji) {
          copyToClipboard(resource.status.toSiteStatus())
        }
      }
    }
  }

  var siteStatusWithEmoji: String {
    let emoji: String
    switch resource.status {
    case .online:
      emoji = "🟢"
    case .offline:
      emoji = "🔴"
    case .unknown:
      emoji = "⚪"
    }
    return "\(emoji) \(resource.status.toSiteStatus())"
  }

  var internetResourceToggleTitle: String {
    store.configuration.internetResourceEnabled ? "Disable this resource" : "Enable this resource"
  }

  var resourceURL: URL? {
    // Try addressDescription first, then address
    if let addressDescription = resource.addressDescription,
      let url = makeURL(from: addressDescription)
    {
      return url
    } else if let address = resource.address,
      let url = makeURL(from: address)
    {
      return url
    }
    return nil
  }

  // Helper to create URL, trying to add https:// scheme if needed
  private func makeURL(from string: String) -> URL? {
    // Reject wildcards
    if string.contains("*") {
      return nil
    }

    // Reject CIDR notation (contains / followed by digits)
    if string.range(of: "/\\d+", options: .regularExpression) != nil {
      return nil
    }

    // Try as-is first
    if let url = URL(string: string), url.host != nil {
      return url
    }
    // If no host, try prepending https://
    if let url = URL(string: "https://\(string)"), url.host != nil {
      return url
    }
    return nil
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

  func copyToClipboard(_ string: String) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.writeObjects([string as NSString])
  }
}

/// Main resources section showing favorites and other resources
struct ResourcesSection: View {
  @EnvironmentObject var store: Store

  /// Partitioned resources (single-pass filtering for performance).
  /// Separates resources into internet, favorites, and others in one iteration
  /// instead of three separate filter passes over the resource list.
  private var partitionedResources:
    (
      internetResource: Resource?,
      favorites: [Resource],
      others: [Resource]
    )
  {
    store.resourceList.asArray().reduce(
      into: (internetResource: nil, favorites: [], others: [])
    ) { result, resource in
      if resource.isInternetResource() {
        result.internetResource = resource
      } else if store.favorites.contains(resource.id) {
        result.favorites.append(resource)
      } else {
        result.others.append(resource)
      }
    }
  }

  var body: some View {
    let resources = partitionedResources

    Group {
      // Header text
      Text(resourcesHeaderText)
        .font(.caption)
        .foregroundStyle(.secondary)

      // Internet resource (always first if present)
      if let internet = resources.internetResource {
        ResourceMenuItem(resource: internet)
      }

      // Favorites (always shown, may be empty)
      if !resources.favorites.isEmpty {
        ForEach(resources.favorites) { resource in
          ResourceMenuItem(resource: resource)
        }
      }

      // Other Resources submenu (only if there are non-favorites)
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
