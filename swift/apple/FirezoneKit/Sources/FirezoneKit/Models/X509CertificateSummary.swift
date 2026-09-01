//
//  X509CertificateSummary.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

/// Why the text a certificate gave a `firezone://` claim is not usable as it.
///
/// Mirrors `ValidationError` of the `x509claims` bindings, which FirezoneKit cannot import.
/// The parser ships the error rather than a sentence so that each client words it itself.
public enum X509ValidationError: Hashable, Sendable {
  case empty
  case tooLong
  case notAnEmailAddress
  case notAUuid
  case ambiguous
  case placeholderIdentifier
  case unknownAttribute
  case notYetValid
  case expired
  case missingClientAuthEku
  case digitalSignatureNotAllowed

  /// A phrase that reads after the claim it explains.
  public var label: String {
    switch self {
    case .empty: return "empty"
    case .tooLong: return "longer than 255 characters"
    case .notAnEmailAddress: return "not a valid email address"
    case .notAUuid: return "not a UUID"
    case .ambiguous: return "more than one value was given"
    case .placeholderIdentifier: return "a placeholder identifier"
    case .unknownAttribute: return "not an attribute we understand"
    case .notYetValid: return "not yet valid"
    case .expired: return "expired"
    case .missingClientAuthEku: return "required for mutual TLS"
    case .digitalSignatureNotAllowed: return "required to sign the TLS handshake"
    }
  }
}

/// One row of the certificate diagnostics screen.
public struct X509CertificateField: Hashable, Sendable {
  public let label: String
  public let value: String?
  /// Why the value above is not usable, `nil` when it is.
  public let problem: X509ValidationError?

  public init(label: String, value: String?, problem: X509ValidationError?) {
    self.label = label
    self.value = value
    self.problem = problem
  }
}

/// Who the certificate says is connecting.
///
/// Mirrors `Identity` of the `x509claims` bindings, which FirezoneKit cannot import.
public enum X509ClaimedIdentity: Hashable, Sendable {
  case absent
  case claimed(email: String?)
}

/// What the parser made of the client certificate the VPN profile references.
public struct X509CertificateSummary: Equatable, Sendable {
  /// Rows to render, in the order the parser produced them.
  public let fields: [X509CertificateField]
  /// Who the certificate says is connecting, which decides what the clients offer.
  public let identity: X509ClaimedIdentity

  public init(fields: [X509CertificateField], identity: X509ClaimedIdentity) {
    self.fields = fields
    self.identity = identity
  }
}

/// A certificate the settings screen can display, plus any problem with its private key.
public struct X509CertificateDetails: Equatable, Sendable {
  public let summary: X509CertificateSummary
  public let keyProblem: String?

  public init(summary: X509CertificateSummary, keyProblem: String?) {
    self.summary = summary
    self.keyProblem = keyProblem
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
  /// `nil` for bytes that are not a certificate.
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
