//
//  AppFilterPolicy.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

/// Which applications may send traffic into the tunnel, and which destinations that guards.
///
/// The packet tunnel writes it to the app group container whenever the tunnel's routes
/// change; the content filter reads it there. A destination is protected when the tunnel
/// routes it, except the tunnel's DNS servers, which the system resolver contacts on
/// behalf of every app. Allowed flows still go through the normal Resource authorization.
///
/// Mirrors `app_filter::Filter` in `rust/libs/app-filter`.
public struct AppFilterPolicy: Codable, Equatable, Sendable {
  public enum Verdict: Equatable, Sendable {
    case allow
    case deny
  }

  /// Signing identifiers of the applications that may use the tunnel; empty means the filter is off.
  public let allowedApps: [String]
  /// CIDR prefixes the tunnel routes.
  public let protectedRoutes: [String]
  /// Addresses that are never filtered, such as the tunnel's DNS servers.
  public let exemptAddresses: [String]

  public static let off = AppFilterPolicy(allowedApplications: nil, protectedRoutes: [], exemptAddresses: [])

  /// `allowedApplications` is the comma-separated managed value; without any entry the filter is off.
  public init(allowedApplications: String?, protectedRoutes: [String], exemptAddresses: [String]) {
    self.allowedApps = Self.parseAllowedApps(allowedApplications)
    self.protectedRoutes = protectedRoutes
    self.exemptAddresses = exemptAddresses
  }

  public var isEnforcing: Bool { !allowedApps.isEmpty }

  public static func parseAllowedApps(_ value: String?) -> [String] {
    (value ?? "")
      .split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
  }

  /// Decides whether `app` may open a flow to `destination`, an IP address literal.
  ///
  /// A flow without app identity is never approved: `nil` only passes to unprotected destinations.
  public func decide(app: String?, destination: String) -> Verdict {
    guard isEnforcing else { return .allow }
    guard let address = IPAddressBytes(destination) else { return .allow }

    if exemptAddresses.contains(where: { IPAddressBytes($0) == address }) {
      return .allow
    }

    let isProtected = protectedRoutes.contains { route in
      guard let prefix = IPPrefix(route) else { return false }
      return prefix.contains(address)
    }
    guard isProtected else { return .allow }

    guard let app, allowedApps.contains(app) else { return .deny }

    return .allow
  }

  // MARK: - Shared storage

  public static var fileURL: URL? {
    SharedAccess.applicationSupportFolderURL?.appendingPathComponent("app-filter-policy.json")
  }

  public static func load(from url: URL? = fileURL) -> AppFilterPolicy? {
    guard let url, let data = try? Data(contentsOf: url) else { return nil }

    return try? JSONDecoder().decode(AppFilterPolicy.self, from: data)
  }

  public func save(to url: URL? = fileURL) throws {
    guard let url else { throw CocoaError(.fileNoSuchFile) }

    try JSONEncoder().encode(self).write(to: url, options: .atomic)
  }
}

/// The bytes of an IPv4 or IPv6 address literal; IPv4-mapped IPv6 addresses collapse to IPv4.
struct IPAddressBytes: Equatable {
  let bytes: [UInt8]

  init?(_ literal: String) {
    var v4 = in_addr()
    if inet_pton(AF_INET, literal, &v4) == 1 {
      bytes = withUnsafeBytes(of: &v4) { Array($0) }
      return
    }

    var v6 = in6_addr()
    guard inet_pton(AF_INET6, literal, &v6) == 1 else { return nil }
    let raw = withUnsafeBytes(of: &v6) { Array($0) }
    let isV4Mapped = raw[..<10].allSatisfy { $0 == 0 } && raw[10] == 0xff && raw[11] == 0xff
    bytes = isV4Mapped ? Array(raw[12...]) : raw
  }
}

struct IPPrefix {
  let network: IPAddressBytes
  let length: Int

  init?(_ cidr: String) {
    let parts = cidr.split(separator: "/", maxSplits: 1)
    guard let network = IPAddressBytes(String(parts[0])) else { return nil }
    let maxLength = network.bytes.count * 8
    let length = parts.count == 2 ? Int(parts[1]) : maxLength
    guard let length, (0...maxLength).contains(length) else { return nil }

    self.network = network
    self.length = length
  }

  func contains(_ address: IPAddressBytes) -> Bool {
    guard address.bytes.count == network.bytes.count else { return false }

    var remaining = length
    for (lhs, rhs) in zip(address.bytes, network.bytes) {
      guard remaining > 0 else { return true }
      let bits = min(remaining, 8)
      let mask = UInt8(truncatingIfNeeded: 0xff << (8 - bits))
      guard lhs & mask == rhs & mask else { return false }
      remaining -= bits
    }

    return true
  }
}
