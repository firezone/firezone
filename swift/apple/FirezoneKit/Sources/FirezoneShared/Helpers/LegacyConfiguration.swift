import Foundation
import NetworkExtension

/// Extracts legacy provider configuration from a tunnel protocol.
///
/// Firezone 1.4.14 and below stored app configuration in the VPN provider configuration
/// fields. This has since been moved to UserDefaults. This function retrieves those
/// legacy values so the tunnel can fall back to them during the migration window.
///
/// - Returns: The legacy key-value configuration, or `nil` if none exists.
public func legacyConfiguration(
  protocolConfiguration: NETunnelProviderProtocol?
  // swiftlint:disable:next discouraged_optional_collection - nil means no legacy config exists
) -> [String: String]? {
  guard let protocolConfiguration,
    let providerConfiguration = protocolConfiguration.providerConfiguration as? [String: String]
  else {
    return nil
  }

  return providerConfiguration
}
