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

    let appStore: AppStore
    @Dependency(\.mainQueue) private var mainQueue

    @Published var loginStatus: AuthStore.LoginStatus = .uninitialized
    @Published var tunnelStatus: NEVPNStatus = .invalid
    @Published var orderedResources: [DisplayableResources.Resource] = []

    init(appStore: AppStore) {
      self.appStore = appStore
      self.logger = appStore.logger
      setupObservers()
    }

    private func setupObservers() {
      appStore.authStore.$loginStatus
        .receive(on: mainQueue)
        .sink { [weak self] loginStatus in
          self?.loginStatus = loginStatus
        }
        .store(in: &cancellables)

      appStore.tunnelStore.$status
        .receive(on: mainQueue)
        .sink { [weak self] status in
          self?.tunnelStatus = status
          if status == .connected {
            self?.appStore.tunnelStore.beginUpdatingResources()
          } else {
            self?.appStore.tunnelStore.endUpdatingResources()
          }
        }
        .store(in: &cancellables)

      appStore.tunnelStore.$resources
        .receive(on: mainQueue)
        .sink { [weak self] resources in
          guard let self = self else { return }
          self.orderedResources = resources.orderedResources.map {
            DisplayableResources.Resource(name: $0.name, location: $0.location)
          }
        }
        .store(in: &cancellables)
    }

    func signOutButtonTapped() {
      Task {
        await appStore.authStore.signOut()
      }
    }

    func startTunnel() async {
      if case .signedIn = self.loginStatus {
        appStore.authStore.startTunnel()
      }
    }

    func stopTunnel() {
      Task {
        do {
          try await appStore.tunnelStore.stop()
        } catch {
          logger.error("\(#function): Error stopping tunnel: \(error)")
        }
      }
    }
  }

  struct MainView: View {
    @ObservedObject var model: MainViewModel

    var body: some View {
      List {
        Section(header: Text("Authentication")) {
          Group {
            switch self.model.loginStatus {
            case .signedIn(let actorName):
              if self.model.tunnelStatus == .connected {
                HStack {
                  Text(actorName.isEmpty ? "Signed in" : "Signed in as")
                  Spacer()
                  Text(actorName)
                    .foregroundColor(.secondary)
                }
                HStack {
                  Spacer()
                  Button("Sign Out") {
                    self.model.signOutButtonTapped()
                  }
                  Spacer()
                }
              } else {
                Text(self.model.tunnelStatus.description)
              }
            case .signedOut:
              Text("Signed Out")
            case .uninitialized:
              Text("Initializing…")
            case .needsTunnelCreationPermission:
              Text("Requires VPN permission")
            }
          }
        }
        if case .signedIn = self.model.loginStatus, self.model.tunnelStatus == .connected {
          Section(header: Text("Resources")) {
            if self.model.orderedResources.isEmpty {
              Text("No resources")
            } else {
              ForEach(self.model.orderedResources) { resource in
                Menu(content: {
                  Button {
                    self.copyResourceTapped(resource)
                  } label: {
                    Label("Copy Address", systemImage: "doc.on.doc")
                  }
                }, label : {
                  HStack {
                    Text(resource.name)
                      .foregroundColor(.primary)
                    Spacer()
                    Text(resource.location)
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
      pasteboard.string = resource.location
    }
  }
#endif
