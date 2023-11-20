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

    auth.$loginStatus
      .receive(on: mainQueue)
      .sink { [weak self] loginStatus in
        Task { [weak self] in
          await self?.handleLoginStatusChanged(loginStatus)
        }
      }
      .store(in: &cancellables)
  }

  private func handleLoginStatusChanged(_ loginStatus: AuthStore.LoginStatus) async {
    switch loginStatus {
    case .signedIn:
      do {
        try await tunnel.start()
      } catch {
        logger.error("Error starting tunnel: \(String(describing: error))")
      }
    case .signedOut:
      tunnel.stop()
    case .uninitialized:
      break
    }
  }

  private func signOutAndStopTunnel() {
    tunnel.stop()
    auth.signOut()
  }
}
