//
//  DeviceTrustCertificateSummary.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

/// Why a certificate diagnostics field is not usable as what it names.
///
/// Mirrors `ValidationError` of the `x509claims` bindings, which FirezoneKit cannot import.
/// The parser ships the error rather than a sentence so that each client words it itself.
public enum DeviceTrustValidationError: Hashable, Sendable {
  case empty
  case tooLong
  case ambiguous
  case placeholderIdentifier
  case unknownAttribute
  case notYetValid
  case expired
  case missingClientAuthEku
  case digitalSignatureNotAllowed

  /// The concise phrase displayed beneath the field.
  public var label: String {
    switch self {
    case .empty: return "empty"
    case .tooLong: return "too long"
    case .ambiguous: return "ambiguous"
    case .placeholderIdentifier: return "placeholder identifier"
    case .unknownAttribute: return "unrecognized attribute"
    case .notYetValid: return "not yet valid"
    case .expired: return "expired"
    case .missingClientAuthEku: return "missing client authentication EKU"
    case .digitalSignatureNotAllowed: return "digital signature not allowed"
    }
  }
}

/// One row of the certificate diagnostics screen.
public struct DeviceTrustCertificateField: Hashable, Sendable {
  public let label: String
  public let value: String?
  /// Why the value above is not usable, `nil` when it is.
  public let problem: DeviceTrustValidationError?

  public init(label: String, value: String?, problem: DeviceTrustValidationError?) {
    self.label = label
    self.value = value
    self.problem = problem
  }
}

/// What the parser made of the client certificate the VPN profile references.
public struct DeviceTrustCertificateSummary: Equatable, Sendable {
  /// Rows to render, in the order the parser produced them.
  public let fields: [DeviceTrustCertificateField]

  public init(fields: [DeviceTrustCertificateField]) {
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
  /// `nil` for bytes that are not a certificate.
  public typealias Parse = @Sendable (Data) -> DeviceTrustCertificateSummary?

  private static var parse: Parse?

  public static func use(_ parse: @escaping Parse) {
    Self.parse = parse
  }

  static func summary(of der: Data) -> DeviceTrustCertificateSummary? {
    guard let parse else {
      Log.warning("No X.509 certificate parser was installed")

      return nil
    }

    return parse(der)
  }
}
