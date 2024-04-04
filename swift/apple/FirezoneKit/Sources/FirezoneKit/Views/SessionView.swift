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
  @Published private(set) var resources: [Resource]? = nil
  @Published private(set) var status: NEVPNStatus? = nil

  let store: Store

  private var cancellables: Set<AnyCancellable> = []

  public init(store: Store) {
    self.store = store

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
          store.beginUpdatingResources() { data in
            self.resources = try? JSONDecoder().decode([Resource].self, from: data)
          }
        } else {
          store.endUpdatingResources()
        }

      })
      .store(in: &cancellables)
    #endif
  }

  func signOutButtonTapped() {
    Task {
      try await store.signOut()
    }
  }
}

#if os(iOS)
@MainActor
struct SessionView: View {
  @ObservedObject var model: SessionViewModel

  var body: some View {
    List {
      Section(header: Text("Authentication")) {
        Group {
          if case .connected = model.status {
            HStack {
              Text("Signed in as")
              Spacer()
              Text(model.actorName ?? "Unknown user").foregroundColor(.secondary)
            }
            HStack {
              Spacer()
              Button("Sign Out") {
                model.signOutButtonTapped()
              }
              Spacer()
            }
          } else {
            Text(model.status?.description ?? "")
          }
        }
      }
      if case .connected = model.status {
        Section(header: Text("Resources")) {
          if let resources = model.resources {
            if resources.isEmpty {
              Text("No Resources")
            } else {
              ForEach(resources) { resource in
                Menu(
                  content: {
                    Button {
                      copyResourceTapped(resource)
                    } label: {
                      Label("Copy Address", systemImage: "doc.on.doc")
                    }
                  },
                  label: {
                    HStack {
                      Text(resource.name)
                        .foregroundColor(.primary)
                      Spacer()
                      Text(resource.address)
                        .foregroundColor(.secondary)
                    }
                  })
              }
            }
          } else {
            Text("Loading Resources...")
          }
        }
      }
    }
    .listStyle(GroupedListStyle())
    .navigationBarTitleDisplayMode(.inline)
    .navigationTitle("Firezone")
  }

  private func copyResourceTapped(_ resource: Resource) {
    let pasteboard = UIPasteboard.general
    pasteboard.string = resource.address
  }
}

#endif
