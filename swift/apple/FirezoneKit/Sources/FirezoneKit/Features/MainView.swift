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

@MainActor
final class MainViewModel: ObservableObject {
  private let logger = Logger.make(for: MainViewModel.self)
  private var cancellables: Set<AnyCancellable> = []

  private let appStore: AppStore

  var authResponse: AuthResponse? {
    switch appStore.auth.loginStatus {
      case .signedIn(let authResponse): return authResponse
      default: return nil
    }
  }

  var status: NEVPNStatus {
    appStore.tunnel.status
  }

  init(appStore: AppStore) {
    self.appStore = appStore

    appStore.objectWillChange
      .sink { [weak self] in self?.objectWillChange.send() }
      .store(in: &cancellables)
  }

  func signOutButtonTapped() {
    appStore.auth.signOut()
  }

  func startTunnel() async {
    do {
      if let authResponse = authResponse {
        try await appStore.tunnel.start(authResponse: authResponse)
      }
    } catch {
      logger.error("Error starting tunnel: \(String(describing: error)) -- signing out")
      appStore.auth.signOut()
    }
  }

  func stopTunnel() {
    appStore.tunnel.stop()
  }
}

struct MainView: View {
  @ObservedObject var model: MainViewModel

  var body: some View {
    VStack(spacing: 56) {
      VStack {
        Text("Authenticated").font(.title)
        Text(model.authResponse?.actorName ?? "").foregroundColor(.secondary)
      }

      Button("Sign out") {
        model.signOutButtonTapped()
      }
    }
    .toolbar {
      ToolbarItem(placement: .principal) {
        ConnectionSwitch(
          status: model.status,
          connect: { await model.startTunnel() },
          disconnect: { model.stopTunnel() }
        )
      }
    }
  }
}

struct MainView_Previews: PreviewProvider {
  static var previews: some View {
    MainView(
      model: MainViewModel(
        appStore: AppStore(
          tunnelStore: TunnelStore(
            tunnel: NETunnelProviderManager()
          )
        )
      )
    )
  }
}
