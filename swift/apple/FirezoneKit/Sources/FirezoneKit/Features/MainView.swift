//
//  MainView.swift
//  (c) 2023 Firezone, Inc.
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
    private let logger = Logger.make(for: MainViewModel.self)
    private var cancellables: Set<AnyCancellable> = []

    let appStore: AppStore
    @Dependency(\.mainQueue) private var mainQueue

    @Published var loginStatus: AuthStore.LoginStatus = .uninitialized
    @Published var tunnelStatus: NEVPNStatus = .invalid
    @Published var orderedResources: [DisplayableResources.Resource] = []

    init(appStore: AppStore) {
      self.appStore = appStore
      setupObservers()
    }

    private func setupObservers() {
      appStore.auth.$loginStatus
        .receive(on: mainQueue)
        .sink { [weak self] loginStatus in
          self?.loginStatus = loginStatus
        }
        .store(in: &cancellables)

      appStore.tunnel.$status
        .receive(on: mainQueue)
        .sink { [weak self] status in
          self?.tunnelStatus = status
          if status == .connected {
            self?.appStore.tunnel.beginUpdatingResources()
          } else {
            self?.appStore.tunnel.endUpdatingResources()
          }
        }
        .store(in: &cancellables)

      appStore.tunnel.$resources
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
        await appStore.auth.signOut()
      }
    }

    func startTunnel() async {
      if case .signedIn = self.loginStatus {
        appStore.auth.startTunnel()
      }
    }

    func stopTunnel() {
      Task {
        do {
          try await appStore.tunnel.stop()
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
                HStack {
                  Text(resource.name)
                  Spacer()
                  Text(resource.location)
                    .foregroundColor(.secondary)
                  Button(
                    role: .none,
                    action: { self.copyResourceTapped(resource) },
                    label: {
                      Label("", systemImage: "doc.on.doc")
                        .symbolRenderingMode(.monochrome)
                        .foregroundColor(.secondary)
                    }
                  )
                }
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

  struct MainView_Previews: PreviewProvider {
    static var previews: some View {
      MainView(
        model: MainViewModel(
          appStore: AppStore(
            tunnelStore: TunnelStore.shared
          )
        )
      )
    }
  }
#endif
