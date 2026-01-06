//
//  SessionView.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Combine
import NetworkExtension
import OSLog
import SwiftUI

#if os(iOS)
  @MainActor
  struct SessionView: View {
    @EnvironmentObject var store: Store

    var body: some View {
      switch store.vpnStatus {
      case .connected:
        if store.configuration.publishedHideResourceList {
          Text("Signed in as \(store.actorName)")
        } else {
          switch store.resourceList {
          case .loaded(let resources):
            if resources.isEmpty {
              Text("No Resources. Contact your admin to be granted access.")
            } else {
              List {
                if !store.favorites.isEmpty() {
                  Section("Favorites") {
                    ResourceSection(resources: favoriteResources())
                  }

                  Section("Other Resources") {
                    ResourceSection(resources: nonFavoriteResources())
                  }
                } else {
                  ResourceSection(resources: resources)
                }
              }
              .listStyle(GroupedListStyle())
            }
          case .loading:
            Text("Loading Resources...")
          }
        }
      case nil:
        Text("Loading VPN configurations from system settings…")
      case .connecting:
        Text("Connecting...")
      case .disconnecting:
        Text("Disconnecting...")
      case .reasserting:
        Text(
          "No internet connection. Resources will be displayed when your internet connection resumes."
        )
      case .invalid:
        Text("VPN permission doesn't seem to be granted.")
      case .disconnected:
        Text("Signed out. Please sign in again to connect to Resources.")
      @unknown default:
        Text("Unknown status. Please report this and attach your logs.")
      }
    }

    func favoriteResources() -> [Resource] {
      switch store.resourceList {
      case .loaded(let resources):
        return resources.filter { store.favorites.contains($0.id) }
      default:
        return []
      }
    }

    func nonFavoriteResources() -> [Resource] {
      switch store.resourceList {
      case .loaded(let resources):
        return resources.filter { !store.favorites.contains($0.id) }
      default:
        return []
      }
    }
  }

  struct ResourceSection: View {
    let resources: [Resource]
    @EnvironmentObject var store: Store

    private func internetResourceTitle(resource: Resource) -> String {
      let status =
        Configuration.shared.internetResourceEnabled ? StatusSymbol.enabled : StatusSymbol.disabled

      return status + " " + resource.name
    }

    private func resourceTitle(resource: Resource) -> String {
      if resource.isInternetResource() {
        return internetResourceTitle(resource: resource)
      }

      return resource.name
    }

    var body: some View {
      ForEach(resources) { resource in
        HStack {
          NavigationLink {
            ResourceView(resource: resource)
          } label: {
            Text(resourceTitle(resource: resource))
          }
        }
        .navigationTitle("All Resources")
      }
    }
  }
#endif
