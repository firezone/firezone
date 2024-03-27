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

    @Published private(set) var resources: [Resource]?

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

      tunnelStore.$resourceListJSON
        .receive(on: mainQueue)
        .sink { [weak self] json in
          guard let self = self,
                let json = json,
                let data = json.data(using: .utf8)
          else { return }

          resources = try? JSONDecoder().decode([Resource].self, from: data)
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
      .navigationTitle("Firezone")
    }

    private func copyResourceTapped(_ resource: Resource) {
      let pasteboard = UIPasteboard.general
      pasteboard.string = resource.address
    }
  }
#endif
