//
//  SystemExtensionManagerProtocol.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

#if os(macOS)
  /// Protocol for system extension management operations.
  ///
  /// This protocol abstracts the macOS system extension APIs to enable
  /// dependency injection for testing. Production uses `SystemExtensionManager`,
  /// tests use `MockSystemExtensionManager`.
  public protocol SystemExtensionManagerProtocol: Sendable {
    /// Checks the current status of the system extension.
    /// - Returns: The current installation status
    func checkStatus() async throws -> SystemExtensionStatus

    /// Installs or updates the system extension.
    /// - Returns: The resulting installation status
    func install() async throws -> SystemExtensionStatus
  }
#endif
