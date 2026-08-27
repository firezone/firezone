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
    case .notAnEmailAddress: return "not a valid email address"
    case .notAUuid: return "not a UUID"
    case .ambiguous: return "more than one value was given"
    case .placeholderIdentifier: return "a placeholder identifier"
    case .unknownAttribute: return "not an attribute we understand"
    }
  }
}

/// A rule a certificate has to satisfy before Firezone can present it for mutual TLS.
///
/// Mirrors `UnusableReason` of the `x509claims` bindings, which FirezoneKit cannot import.
/// The parser ships the rule rather than a sentence so that each client words it itself.
public enum X509UnusableReason: Hashable, Sendable {
  case noClientAuthEku
  case noDigitalSignatureKeyUsage
  case notYetValid
  case expired
  case unsupportedKeyAlgorithm
  case unreadable

  /// A sentence that reads underneath the attribute the rule is about.
  public var sentence: String {
    switch self {
    case .noClientAuthEku:
      return "Firezone only presents a certificate that allows TLS client authentication."
    case .noDigitalSignatureKeyUsage:
      return "Firezone only presents a certificate whose key usage allows digital signatures."
    case .notYetValid: return "This certificate is not valid yet."
    case .expired: return "This certificate has expired."
    case .unsupportedKeyAlgorithm: return "Firezone cannot sign with this key algorithm."
    case .unreadable: return "Firezone could not read this certificate."
    }
  }
}

/// The text one row of the diagnostics screen shows, above whatever is wrong with it.
public enum X509ClaimValue: Hashable, Sendable {
  case present(String)
  case absent
}

/// What is wrong with one row, read underneath the value it belongs to.
public enum X509FieldProblem: Hashable, Sendable {
  case rejected(X509ClaimRejection)
  case unusable(X509UnusableReason)
}

/// One row of the certificate diagnostics screen.
public struct X509CertificateField: Hashable, Sendable {
  public let label: String
  public let value: X509ClaimValue
  /// What is wrong with the value above, `nil` when nothing is.
  public let problem: X509FieldProblem?

  public init(label: String, value: X509ClaimValue, problem: X509FieldProblem?) {
    self.label = label
    self.value = value
    self.problem = problem
  }
}

/// What the parser made of the client certificate the VPN profile references.
public struct X509CertificateSummary: Equatable, Sendable {
  /// Whether the certificate's own rules allow presenting it for mutual TLS.
  public let isUsable: Bool
  /// The rules it fails that no row carries, which the card states with the verdict.
  public let certificateProblems: [X509UnusableReason]
  /// Rows to render, in the order the parser produced them.
  public let fields: [X509CertificateField]

  public init(
    isUsable: Bool,
    certificateProblems: [X509UnusableReason],
    fields: [X509CertificateField]
  ) {
    self.isUsable = isUsable
    self.certificateProblems = certificateProblems
    self.fields = fields
  }

  /// Bytes that are not a certificate, reported as one that fails a rule so that the
  /// screen states the same verdict it states for every certificate it will not present.
  public static let unreadable = X509CertificateSummary(
    isUsable: false, certificateProblems: [.unreadable], fields: [])
}

/// Where the app installs the certificate parser.
///
/// Parsing happens in Rust and reaches Swift through the `x509claims` UniFFI
/// bindings, which are compiled into the app and Network Extension targets.
/// FirezoneKit is a Swift package and cannot import them, so the app hands the
/// parser over during startup and the diagnostics screen calls back into it.
@MainActor
public enum X509CertificateParser {
  public typealias Parse = @Sendable (Data) -> X509CertificateSummary

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
