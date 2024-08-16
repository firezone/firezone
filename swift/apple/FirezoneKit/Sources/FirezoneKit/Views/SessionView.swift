//
//  SessionView.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Combine
import NetworkExtension
import OSLog
import SwiftUI

@MainActor
public final class SessionViewModel: ObservableObject {
  @Published private(set) var actorName: String? = nil
  @Published private(set) var resources: [Resource] = []
  @Published private(set) var status: NEVPNStatus? = nil

  let favorites: Favorites
  let store: Store

  private var cancellables: Set<AnyCancellable> = []

  public init(favorites: Favorites, store: Store) {
    self.favorites = favorites
    self.store = store

    favorites.$ids
      .receive(on: DispatchQueue.main)
      .sink(receiveValue: { [weak self] ids in
        guard let self = self else { return }
        // TODO: Refresh menu
      })
      .store(in: &cancellables)

    store.$actorName
      .receive(on: DispatchQueue.main)
      .sink(receiveValue: { [weak self] actorName in
        guard let self = self else { return }

        self.actorName = actorName
      })
      .store(in: &cancellables)

    // MenuBar has its own observer
#if os(iOS)
    store.$status
      .receive(on: DispatchQueue.main)
      .sink(receiveValue: { [weak self] status in
        guard let self = self else { return }
        self.status = status

        if status == .connected {
          store.beginUpdatingResources() { resources in
            self.resources = resources
          }
        } else {
          store.endUpdatingResources()
        }

      })
      .store(in: &cancellables)
#endif
  }

  public func isResourceEnabled(_ resource: String) -> Bool {
    store.isResourceEnabled(resource)
  }

}

#if os(iOS)
@MainActor
struct SessionView: View {
  @ObservedObject var model: SessionViewModel

  var body: some View {
    switch model.status {
    case .connected:
        if resources.isEmpty {
          Text("No Resources. Contact your admin to be granted access.")
        } else {
          List {
            Section(header: Text("Favorites")) {
              ForEach(resources.filter { model.favorites.contains($0.id) }) { resource in
                HStack {
                  NavigationLink { ResourceView(resource: resource) }
                label: {
                  HStack {
                    Text(resource.name)
                    if resource.canToggle {
                      Spacer()
                      Toggle("Enabled", isOn: Binding<Bool>(
                        get: { model.isResourceEnabled(resource.id) },
                        set: { newValue in
                          model.store.toggleResourceDisabled(resource: resource.id, enabled: newValue)
                        }
                      )).labelsHidden()
                    }
                  }
                }
                .navigationTitle("All Resources")
                }
              }
            }

            Section(header: Text("Other Resources")) {
              ForEach(resources.filter { !model.favorites.contains($0.id) }) { resource in
                HStack {
                  NavigationLink { ResourceView(resource: resource) }
                label: {
                  HStack {
                    Text(resource.name)
                    if resource.canToggle {
                      Spacer()
                      Toggle("Enabled", isOn: Binding<Bool>(
                        get: { model.isResourceEnabled(resource.id) },
                        set: { newValue in
                          model.store.toggleResourceDisabled(resource: resource.id, enabled: newValue)
                        }
                      )).labelsHidden()
                    }
                  }
                }
                .navigationTitle("All Resources")
                }
              }
            }
          }

          .listStyle(GroupedListStyle())
        }
      } else {
        Text("Loading Resources...")
      }
    case .connecting:
      Text("Connecting...")
    case .disconnecting:
      Text("Disconnecting...")
    case .reasserting:
      Text("No internet connection. Resources will be displayed when your internet connection resumes.")
    case .invalid, .none:
      Text("VPN permission doesn't seem to be granted.")
    case .disconnected:
      Text("Signed out. Please sign in again to connect to Resources.")
    @unknown default:
      Text("Unknown status. Please report this and attach your logs.")
    }
  }
}
#endif
