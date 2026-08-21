//
//  X509CertificateSummary.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

/// One row of the certificate diagnostics screen.
public struct X509CertificateField: Hashable, Sendable {
  public let label: String
  public let value: String

  public init(label: String, value: String) {
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
