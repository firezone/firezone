//
//  X509CertificateMetadata.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

public struct X509CertificateMetadata: Equatable, Sendable {
  public let subjectCommonName: String
  public let sanValues: [String]
  public let extendedKeyUsageValues: [String]
  public let notBefore: Date?
  public let notAfter: Date?

  public init(
    subjectCommonName: String,
    sanValues: [String],
    extendedKeyUsageValues: [String],
    notBefore: Date? = nil,
    notAfter: Date? = nil
  ) {
    self.subjectCommonName = subjectCommonName
    self.sanValues = sanValues
    self.extendedKeyUsageValues = extendedKeyUsageValues
    self.notBefore = notBefore
    self.notAfter = notAfter
  }
}

public enum X509CertificatePolicy {
  public static let clientAuthenticationExtendedKeyUsageOID = "1.3.6.1.5.5.7.3.2"

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
    metadata.extendedKeyUsageValues.contains { value in
      let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

      return normalized == clientAuthenticationExtendedKeyUsageOID
        || normalized.contains(clientAuthenticationExtendedKeyUsageOID)
        || normalized.contains("client authentication")
        || normalized.contains("client auth")
    }
  }

  public static func isValid(_ metadata: X509CertificateMetadata, now: Date = Date()) -> Bool {
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
    switch (lhs.notBefore, rhs.notBefore) {
    case let (lhsDate?, rhsDate?):
      if lhsDate != rhsDate {
        return lhsDate < rhsDate
      }
    case (.none, .some):
      return true
    case (.some, .none):
      return false
    case (.none, .none):
      break
    }

    switch (lhs.notAfter, rhs.notAfter) {
    case let (lhsDate?, rhsDate?):
      if lhsDate != rhsDate {
        return lhsDate < rhsDate
      }
    case (.none, .some):
      return true
    case (.some, .none):
      return false
    case (.none, .none):
      break
    }

    return false
  }
}
