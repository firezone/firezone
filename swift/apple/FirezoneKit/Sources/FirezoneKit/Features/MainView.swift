//
//  MainView.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Combine
import Dependencies
import NetworkExtension
import OSLog
import SwiftUI

#if os(iOS)
  @MainActor
  final class MainViewModel: ObservableObject {
    private let logger: AppLogger
    private var cancellables: Set<AnyCancellable> = []

    let tunnelStore: TunnelStore
    @Dependency(\.mainQueue) private var mainQueue

    @Published var displayableResources: [DisplayableResources.Resource] = []

    init(tunnelStore: TunnelStore, logger: AppLogger) {
      self.tunnelStore = tunnelStore
      self.logger = logger
      setupObservers()
    }

    private func setupObservers() {
      tunnelStore.$status
        .receive(on: mainQueue)
        .sink { [weak self] status in
          guard let self = self else { return }
          if status == .connected {
            self.tunnelStore.beginUpdatingResources()
          } else {
            self.tunnelStore.endUpdatingResources()
          }
        }
        .store(in: &cancellables)

      tunnelStore.$displayableResources
        .receive(on: mainQueue)
        .sink { [weak self] displayableResources in
          guard let self = self else { return }
          self.displayableResources = displayableResources.resources.map {
            DisplayableResources.Resource(name: $0.name, address: $0.address)
          }
        }
        .store(in: &cancellables)
    }

    func signOutButtonTapped() {
      Task {
        try await tunnelStore.signOut()
      }
    }
  }

  struct MainView: View {
    @ObservedObject var model: MainViewModel

    var body: some View {
      List {
        Section(header: Text("Authentication")) {
          Group {
            if case .connected = model.tunnelStore.status {
              let actorName = model.tunnelStore.actorName() ?? ""
              HStack {
                Text(actorName.isEmpty ? "Signed in" : "Signed in as")
                Spacer()
                Text(actorName).foregroundColor(.secondary)
              }
              HStack {
                Spacer()
                Button("Sign Out") {
                  model.signOutButtonTapped()
                }
                Spacer()
              }
            } else {
              Text(model.tunnelStore.status.description)
            }
          }
        }
        if case .connected = model.tunnelStore.status {
          Section(header: Text("Resources")) {
            if model.displayableResources.isEmpty {
              Text("No resources")
            } else {
              ForEach(model.displayableResources) { displayableResource in
                Menu(
                  content: {
                    Button {
                      copyResourceTapped(displayableResource)
                    } label: {
                      Label("Copy Address", systemImage: "doc.on.doc")
                    }
                  },
                  label: {
                    HStack {
                      Text(displayableResource.name)
                        .foregroundColor(.primary)
                      Spacer()
                      Text(displayableResource.address)
                        .foregroundColor(.secondary)
                    }
                  })
              }
            }
          }
        }
      }
      .listStyle(GroupedListStyle())
      .navigationTitle("Firezone")
    }

    private func copyResourceTapped(_ resource: DisplayableResources.Resource) {
      let pasteboard = UIPasteboard.general
      pasteboard.string = resource.address
    }
  }
#endif
