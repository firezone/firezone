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
  @Published private(set) var favorites: Favorites
  @Published private(set) var resources: ResourceList = ResourceList.loading
  @Published private(set) var status: NEVPNStatus = .disconnected

  let store: Store

  private var cancellables: Set<AnyCancellable> = []

  public init(favorites: Favorites, store: Store) {
    self.favorites = favorites
    self.store = store

    favorites.$ids
      .receive(on: DispatchQueue.main)
      .sink(receiveValue: { [weak self] ids in
        guard let self = self else { return }
        self.objectWillChange.send()
      })
      .store(in: &cancellables)

    store.$actorName
      .receive(on: DispatchQueue.main)
      .sink(receiveValue: { [weak self] actorName in
        guard let self = self else { return }

        self.actorName = actorName
      })
      .store(in: &cancellables)

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
          self.resources = ResourceList.loading
        }

      })
      .store(in: &cancellables)
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
      switch model.resources {
      case .loaded(let resources):
        if resources.isEmpty {
          Text("No Resources. Contact your admin to be granted access.")
        } else {
          List {
            let hasAnyFavorites = resources.contains { model.favorites.contains($0.id) }
            if hasAnyFavorites {
              Section("Favorites") {
                ResourceSection(
                  resources: resources.filter { model.favorites.contains($0.id) },
                  model: model
                )
              }

              Section("Other Resources") {
                ResourceSection(
                  resources: resources.filter { !model.favorites.contains($0.id) },
                  model: model
                )
              }
            } else {
              ResourceSection(
                resources: resources,
                model: model
              )
            }
          }
          .listStyle(GroupedListStyle())
        }
      case .loading:
        Text("Loading Resources...")
      }
    case .connecting:
      Text("Connecting...")
    case .disconnecting:
      Text("Disconnecting...")
    case .reasserting:
      Text("No internet connection. Resources will be displayed when your internet connection resumes.")
    case .invalid:
      Text("VPN permission doesn't seem to be granted.")
    case .disconnected:
      Text("Signed out. Please sign in again to connect to Resources.")
    @unknown default:
      Text("Unknown status. Please report this and attach your logs.")
    }
  }
}

struct ResourceSection: View {
  let resources: [Resource]
  @ObservedObject var model: SessionViewModel

  var body: some View {
    ForEach(resources) { resource in
      HStack {
        if !resource.isInternetResource() {
            NavigationLink { ResourceView(model: model, resource: resource) }
          label: {
            ResourceLable(resource: resource, model: model )
          }
        } else {
          ResourceLable(resource: resource, model: model)
        }
      }
      .navigationTitle("All Resources")
    }
  }
}

struct ResourceLable: View {
  let resource: Resource
  @ObservedObject var model: SessionViewModel

  var body: some View {
    HStack {
      Text(resource.name)
      if resource.canBeDisabled {
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
}
#endif
