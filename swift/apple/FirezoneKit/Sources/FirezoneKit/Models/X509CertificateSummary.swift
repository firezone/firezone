//
//  X509CertificateSummary.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

/// Why a `firezone://` claim the certificate carries was not attested.
///
/// Mirrors `RejectionReason` of the `x509claims` bindings, which FirezoneKit cannot import.
/// The parser ships the reason rather than a sentence so that each client words it itself.
public enum X509ClaimRejection: Hashable, Sendable {
  case empty
  case tooLong
  case notAnEmailAddress
  case notAUuid
  case ambiguous
  case placeholderIdentifier
  case unknownAttribute

  /// A phrase that reads after the claim it explains.
  public var reason: String {
    switch self {
    case .empty: return "empty"
    case .tooLong: return "longer than 255 characters"
    case .notAnEmailAddress: return "not an email address"
    case .notAUuid: return "not a UUID"
    case .ambiguous: return "more than one value was given"
    case .placeholderIdentifier: return "a placeholder identifier"
    case .unknownAttribute: return "not an attribute we understand"
    }
  }
}

/// What the certificate says about one row of the diagnostics screen.
public enum X509ClaimValue: Hashable, Sendable {
  case present(String)
  case absent
  case invalid(X509ClaimRejection)
}

/// One row of the certificate diagnostics screen.
public struct X509CertificateField: Hashable, Sendable {
  public let label: String
  public let value: X509ClaimValue

  public init(label: String, value: X509ClaimValue) {
    self.label = label
    self.value = value
  }
}

/// What the parser made of the client certificate the VPN profile references.
public struct X509CertificateSummary: Equatable, Sendable {
  /// Why this certificate cannot be presented for mutual TLS, `nil` if it can.
  public let unusableSummary: String?
  /// Rows to render, in the order the parser produced them.
  public let fields: [X509CertificateField]

  public init(unusableSummary: String?, fields: [X509CertificateField]) {
    self.unusableSummary = unusableSummary
    self.fields = fields
  }
}

/// Where the app installs the certificate parser.
///
/// Parsing happens in Rust and reaches Swift through the `x509claims` UniFFI
/// bindings, which are compiled into the app and Network Extension targets.
/// FirezoneKit is a Swift package and cannot import them, so the app hands the
/// parser over during startup and the diagnostics screen calls back into it.
@MainActor
public enum X509CertificateParser {
  public typealias Parse = @Sendable (Data) -> X509CertificateSummary?

  private static var parse: Parse?

  public static func use(_ parse: @escaping Parse) {
    Self.parse = parse
  }

  static func summary(of der: Data) -> X509CertificateSummary? {
    guard let parse else {
      Log.warning("No X.509 certificate parser was installed")

      return nil
    }

    return parse(der)
  }
}
