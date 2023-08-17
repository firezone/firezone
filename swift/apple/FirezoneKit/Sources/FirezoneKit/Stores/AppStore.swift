//
//  AppStore.swift
//  (c) 2023 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Combine
import Dependencies
import OSLog

@MainActor
final class AppStore: ObservableObject {
  private let logger = Logger.make(for: AppStore.self)

  @Dependency(\.authStore) var auth
  @Dependency(\.mainQueue) var mainQueue

  let tunnel: TunnelStore
  private var cancellables: Set<AnyCancellable> = []

  init(tunnelStore: TunnelStore) {
    tunnel = tunnelStore

    Publishers.Merge(
      auth.objectWillChange,
      tunnel.objectWillChange
    )
    .receive(on: mainQueue)
    .sink { [weak self] in
      self?.objectWillChange.send()
    }
    .store(in: &cancellables)

    auth.$authResponse
      .receive(on: mainQueue)
      .sink { [weak self] authResponse in
        Task { [weak self] in
          await self?.handleAuthResponseChanged(authResponse)
        }
      }
      .store(in: &cancellables)
  }

  private func handleAuthResponseChanged(_ authResponse: AuthResponse?) async {
    if let authResponse = authResponse {
      do {
        try await tunnel.start(authResponse: authResponse)
      } catch {
        logger.error("Error starting tunnel: \(String(describing: error)) -- signing out")
        auth.signOut()
      }
    } else {
      tunnel.stop()
    }
  }

  private func signOutAndStopTunnel() {
    tunnel.stop()
    auth.signOut()
  }
}
