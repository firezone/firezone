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

    auth.$token
      .receive(on: mainQueue)
      .sink { [weak self] token in
        Task { [weak self] in
          await self?.handleTokenChanged(token)
        }
      }
      .store(in: &cancellables)
  }

  private func handleTokenChanged(_ token: Token?) async {
    if let token = token {
      do {
        try await tunnel.start(token: token)
      } catch {
        logger.error("Error starting tunnel: \(String(describing: error))")
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
