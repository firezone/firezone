//
//  X509CertificateMetadata.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

/// Public certificate fields used for local pre-filtering before signing a device-trust nonce.
///
/// This metadata is not itself trusted identity. It is only a way to choose which local Keychain
/// identity should be asked to sign. The server still verifies the returned leaf certificate,
/// validates its issuer chain, and checks the signature over the nonce.
public struct X509CertificateMetadata: Equatable, Sendable {
  public let subjectCommonName: String
  public let extendedKeyUsageValues: [String]
  public let notBefore: Date?
  public let notAfter: Date?

  public init(
    subjectCommonName: String,
    extendedKeyUsageValues: [String],
    notBefore: Date? = nil,
    notAfter: Date? = nil
  ) {
    self.subjectCommonName = subjectCommonName
    self.extendedKeyUsageValues = extendedKeyUsageValues
    self.notBefore = notBefore
    self.notAfter = notAfter
  }
}

public enum X509CertificatePolicy {
  // RFC 5280 / PKIX keyPurposeId for TLS Web Client Authentication. Requiring this EKU prevents
  // using unrelated certificates, such as server-auth-only or email certificates, for device trust.
  public static let clientAuthenticationExtendedKeyUsageOID = "1.3.6.1.5.5.7.3.2"

  /// Returns true only when a certificate is locally eligible for device-trust signing.
  ///
  /// The local checks are deliberately narrow:
  /// - Subject CN must match the server-requested convention for this device-trust flow.
  /// - EKU must include Client Authentication, so we do not sign with arbitrary certs.
  /// - The cert must be inside its validity window if those dates were parsed.
  public static func matchesClientAuthIdentity(
    _ metadata: X509CertificateMetadata,
    subjectCommonName: String,
    now: Date = Date()
  ) -> Bool {
    metadata.subjectCommonName == subjectCommonName
      && hasClientAuthenticationExtendedKeyUsage(metadata)
      && isValid(metadata, now: now)
  }

  public static func hasClientAuthenticationExtendedKeyUsage(
    _ metadata: X509CertificateMetadata
  ) -> Bool {
    // The DER parser returns OIDs. Security.framework on macOS can expose localized labels in
    // tests or diagnostics, so accept both representations.
    metadata.extendedKeyUsageValues.contains { value in
      let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

      return normalized == clientAuthenticationExtendedKeyUsageOID
        || normalized.contains(clientAuthenticationExtendedKeyUsageOID)
        || normalized.contains("client authentication")
        || normalized.contains("client auth")
    }
  }

  public static func isValid(_ metadata: X509CertificateMetadata, now: Date = Date()) -> Bool {
    // `notBefore` and `notAfter` are local preflight checks only. The server still validates the
    // returned certificate chain and validity when it verifies the signed nonce.
    if let notBefore = metadata.notBefore, now < notBefore {
      return false
    }
    if let notAfter = metadata.notAfter, now > notAfter {
      return false
    }

    return true
  }

  public static func isOlder(_ lhs: X509CertificateMetadata, than rhs: X509CertificateMetadata)
    -> Bool
  {
    // Prefer the newest matching certificate when MDM rotates device certs and old certs remain in
    // the Keychain. `notBefore` is the primary rotation signal; `notAfter` breaks ties.
    if let result = dateComparison(lhs.notBefore, rhs.notBefore) {
      return result == .orderedAscending
    }
    if let result = dateComparison(lhs.notAfter, rhs.notAfter) {
      return result == .orderedAscending
    }

    return false
  }

  private static func dateComparison(_ lhs: Date?, _ rhs: Date?) -> ComparisonResult? {
    switch (lhs, rhs) {
    case (let lhsDate?, let rhsDate?) where lhsDate != rhsDate:
      return lhsDate < rhsDate ? .orderedAscending : .orderedDescending
    case (.none, .some):
      return .orderedAscending
    case (.some, .none):
      return .orderedDescending
    default:
      return nil
    }
  }
}
