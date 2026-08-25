//
//  X509CertificateSource.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

/// Where the certificate diagnostics screen gets the certificate it shows.
///
/// The screen reads the keychain in production. A source built from a certificate
/// handed in lets previews, screenshots and tests show one without a keychain.
public struct X509CertificateSource: Sendable {
  /// Reads the persistent keychain reference from the VPN configuration.
  public typealias IdentityReference = @MainActor @Sendable () throws -> Data?

  /// The DER-encoded end-entity certificate, plus why its private key cannot sign.
  public typealias Reading = (certificate: Data?, keyProblem: String?)

  let read: @MainActor @Sendable () async throws -> Reading

  /// Reads the identity the VPN configuration references.
  public static func keychain(identityReference: @escaping IdentityReference) -> Self {
    X509CertificateSource {
      let reference = try identityReference()
      // Reading the keychain can block, and this runs while the settings window is open.
      let (certificate, keyProblem) = try await Task.detached(priority: .userInitiated) {
        let certificate = try X509Identity.leafCertificate(persistentReference: reference)
        let keyProblem =
          certificate == nil
          ? nil
          : reference.flatMap(X509Identity.privateKeyProblem(persistentReference:))

        return (certificate, keyProblem)
      }.value

      return (certificate: certificate, keyProblem: keyProblem)
    }
  }

  /// Shows a certificate that is handed in rather than read from the keychain.
  public static func fixed(certificate: Data?, keyProblem: String? = nil) -> Self {
    let reading: Reading = (certificate: certificate, keyProblem: keyProblem)

    return X509CertificateSource { reading }
  }
}
