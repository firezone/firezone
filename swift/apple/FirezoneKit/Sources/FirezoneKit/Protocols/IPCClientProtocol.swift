//
//  IPCClientProtocol.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
import NetworkExtension

/// Abstracts IPC communication with the tunnel process.
///
/// This protocol enables dependency injection for testing Store's resource
/// fetching and configuration logic without a real Network Extension.
@MainActor
protocol IPCClientProtocol {
  func fetchResources(currentHash: Data) async throws -> Data?
  func setConfiguration(_ config: TunnelConfiguration) async throws
  func start() throws
  func start(token: String) throws
  func signOut() async throws
  func clearLogs() async throws
}

/// Default implementation wrapping the static IPCClient methods.
@MainActor
struct RealIPCClient: IPCClientProtocol {
  let session: NETunnelProviderSession

  func fetchResources(currentHash: Data) async throws -> Data? {
    try await IPCClient.fetchResources(session: session, currentHash: currentHash)
  }

  func setConfiguration(_ config: TunnelConfiguration) async throws {
    try await IPCClient.setConfiguration(session: session, config)
  }

  func start() throws {
    try IPCClient.start(session: session)
  }

  func start(token: String) throws {
    try IPCClient.start(session: session, token: token)
  }

  func signOut() async throws {
    try await IPCClient.signOut(session: session)
  }

  func clearLogs() async throws {
    try await IPCClient.clearLogs(session: session)
  }
}
