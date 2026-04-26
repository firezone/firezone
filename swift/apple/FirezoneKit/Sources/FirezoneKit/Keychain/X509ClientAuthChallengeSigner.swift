//
//  X509ClientAuthChallengeSigner.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import CryptoKit
import Foundation
import Security

/// Produces device-trust proofs using client-authentication X.509 identities in the Apple Keychain.
///
/// The private key never leaves the Keychain/Secure Enclave. This type only:
/// 1. Finds candidate identities by certificate metadata.
/// 2. Asks Security.framework to sign the server nonce with the matching private key.
/// 3. Returns the signature and public leaf certificate DER so the server can verify the proof.
public struct X509ClientAuthChallengeSigner {
  public struct SignedChallenge: Codable, Equatable, Sendable {
    /// Signature over the server-provided nonce. This proves possession of the private key that
    /// corresponds to `leafCertificateDERBase64`.
    public let signedChallengeBase64: String

    /// Public leaf certificate only. DER certificates do not contain private key material.
    public let leafCertificateDERBase64: String

    public init(signedChallengeBase64: String, leafCertificateDERBase64: String) {
      self.signedChallengeBase64 = signedChallengeBase64
      self.leafCertificateDERBase64 = leafCertificateDERBase64
    }
  }

  public enum Error: LocalizedError, Equatable {
    case invalidNonceBase64
    case invalidNonceLength(expected: Int, actual: Int)
    case identityQueryFailed(OSStatus)
    case identityCertificateCopyFailed(OSStatus)
    case signatureCreationFailed(String)
    case unexpectedFailure(String)

    public var errorDescription: String? {
      switch self {
      case .invalidNonceBase64:
        return "Device trust nonce is not valid base64."
      case .invalidNonceLength(let expected, let actual):
        return "Device trust nonce must be \(expected) bytes, got \(actual)."
      case .identityQueryFailed(let status):
        return "Identity query failed: \(statusMessage(status))"
      case .identityCertificateCopyFailed(let status):
        return "Identity certificate lookup failed: \(statusMessage(status))"
      case .signatureCreationFailed(let message):
        return "Signature creation failed: \(message)"
      case .unexpectedFailure(let message):
        return "Unexpected X.509 signer failure: \(message)"
      }
    }
  }

  private static let nonceByteCount = 32

  private let loadIdentities: () throws -> [X509IdentityRecord]

  public init() {
    self.init(loadIdentities: loadX509ClientAuthIdentityRecords)
  }

  init(loadIdentities: @escaping () throws -> [X509IdentityRecord]) {
    self.loadIdentities = loadIdentities
  }

  public func signChallenges(
    nonceBase64: String,
    subjectCommonName: String
  ) throws -> [SignedChallenge] {
    guard let nonce = Data(base64Encoded: nonceBase64) else {
      throw Error.invalidNonceBase64
    }

    return try signChallenges(nonce: nonce, subjectCommonName: subjectCommonName)
  }

  public func signChallenges(
    nonce: Data,
    subjectCommonName: String
  ) throws -> [SignedChallenge] {
    // The server sends 32 bytes of randomness. Signing a fixed-length nonce prevents replaying
    // stale proofs and keeps the signed payload deliberately small and unambiguous.
    guard nonce.count == Self.nonceByteCount else {
      throw Error.invalidNonceLength(expected: Self.nonceByteCount, actual: nonce.count)
    }

    let identities: [X509IdentityRecord]

    do {
      identities = try loadIdentities()
    } catch let error as Error {
      throw error
    } catch {
      throw Error.unexpectedFailure(String(describing: error))
    }

    let now = Date()
    Log.debug(
      "Device trust signer: loaded \(identities.count) Keychain identity candidate(s) for subject CN \(subjectCommonName)"
    )

    let matches = identities.compactMap { identity -> SignableX509Identity? in
      let certSHA256 = identity.certificateDER.sha256HexString()

      // Filter on public certificate metadata before asking Keychain for the private key. This
      // avoids touching unrelated keys and reduces the chance of triggering authorization UI.
      guard
        X509CertificatePolicy.matchesClientAuthIdentity(
          identity.metadata,
          subjectCommonName: subjectCommonName,
          now: now
        )
      else {
        Log.debug(
          "Device trust signer: skipping cert_sha256=\(certSHA256) subject_cn=\(identity.metadata.subjectCommonName) eku=\(identity.metadata.extendedKeyUsageValues) not_before=\(String(describing: identity.metadata.notBefore)) not_after=\(String(describing: identity.metadata.notAfter))"
        )
        return nil
      }
      guard let signingKey = identity.copySigningKey() else {
        Log.debug(
          "Device trust signer: skipping cert_sha256=\(certSHA256) subject_cn=\(identity.metadata.subjectCommonName) reason=private_key_unavailable"
        )
        return nil
      }

      // The concrete key type determines which signature algorithms are supported. We choose the
      // first supported algorithm from a stable preference list below.
      guard let algorithm = chooseSignatureAlgorithm(for: signingKey) else {
        Log.debug(
          "Device trust signer: skipping cert_sha256=\(certSHA256) subject_cn=\(identity.metadata.subjectCommonName) reason=no_supported_signature_algorithm"
        )
        return nil
      }

      Log.debug(
        "Device trust signer: selected cert_sha256=\(certSHA256) subject_cn=\(identity.metadata.subjectCommonName) algorithm=\(algorithm)"
      )

      return SignableX509Identity(
        record: identity,
        signingKey: signingKey,
        algorithm: algorithm
      )
    }
    .sorted(by: isPreferredSignableIdentity(_:over:))

    Log.debug("Device trust signer: signing \(matches.count) challenge(s)")

    let signedChallenges: [SignedChallenge] = matches.compactMap { match -> SignedChallenge? in
      let certSHA256 = match.record.certificateDER.sha256HexString()
      let signature: Data

      do {
        signature = try match.signingKey.sign(challenge: nonce, algorithm: match.algorithm)
      } catch {
        // A key can look usable during identity lookup but still reject the actual signing
        // operation, commonly because its Keychain ACL requires UI. The Network Extension must not
        // prompt, so skip this identity and keep trying any other matching certs.
        Log.debug(
          "Device trust signer: skipping cert_sha256=\(certSHA256) subject_cn=\(match.record.metadata.subjectCommonName) reason=signature_failed error=\(error)"
        )
        return nil
      }

      Log.debug(
        "Device trust signer: signed cert_sha256=\(certSHA256) subject_cn=\(match.record.metadata.subjectCommonName) algorithm=\(match.algorithm) signature_byte_count=\(signature.count)"
      )

      return SignedChallenge(
        signedChallengeBase64: signature.base64EncodedString(),
        leafCertificateDERBase64: match.record.certificateDER.base64EncodedString()
      )
    }

    Log.debug("Device trust signer: produced \(signedChallenges.count) signed challenge(s)")
    return signedChallenges
  }

  private func chooseSignatureAlgorithm(for signingKey: any X509ChallengeSigningKey)
    -> X509SignatureAlgorithm?
  {
    // These are message-level Security.framework algorithms: Security hashes the nonce with
    // SHA-256 and then signs. PKCS#1 v1.5 is tried first because it is the most widely supported
    // by MDM-issued RSA client-auth certs; ECDSA handles EC keys; PSS is accepted when available.
    let candidates: [X509SignatureAlgorithm] = [
      .rsaSignatureMessagePKCS1v15SHA256,
      .ecdsaSignatureMessageX962SHA256,
      .rsaSignatureMessagePSSSHA256,
    ]

    return candidates.first(where: signingKey.isAlgorithmSupported)
  }

  private func isPreferredSignableIdentity(
    _ lhs: SignableX509Identity,
    over rhs: SignableX509Identity
  ) -> Bool {
    if X509CertificatePolicy.isOlder(lhs.record.metadata, than: rhs.record.metadata) {
      return false
    }
    if X509CertificatePolicy.isOlder(rhs.record.metadata, than: lhs.record.metadata) {
      return true
    }

    return lhs.record.certificateDER.lexicographicallyPrecedes(rhs.record.certificateDER)
  }
}

struct X509IdentityRecord {
  let certificateDER: Data
  let metadata: X509CertificateMetadata

  /// Deferred private-key lookup. Keep this lazy so filtering can happen on public certificate
  /// bytes and metadata before Security.framework is asked to access key material.
  let copySigningKey: () -> (any X509ChallengeSigningKey)?
}

private struct SignableX509Identity {
  let record: X509IdentityRecord
  let signingKey: any X509ChallengeSigningKey
  let algorithm: X509SignatureAlgorithm
}

enum X509SignatureAlgorithm: Hashable {
  case rsaSignatureMessagePKCS1v15SHA256
  case rsaSignatureMessagePSSSHA256
  case ecdsaSignatureMessageX962SHA256

  fileprivate var securityAlgorithm: SecKeyAlgorithm {
    switch self {
    case .rsaSignatureMessagePKCS1v15SHA256:
      return .rsaSignatureMessagePKCS1v15SHA256
    case .rsaSignatureMessagePSSSHA256:
      return .rsaSignatureMessagePSSSHA256
    case .ecdsaSignatureMessageX962SHA256:
      return .ecdsaSignatureMessageX962SHA256
    }
  }
}

extension X509SignatureAlgorithm: CustomStringConvertible {
  var description: String {
    switch self {
    case .rsaSignatureMessagePKCS1v15SHA256:
      return "rsa_pkcs1_sha256"
    case .rsaSignatureMessagePSSSHA256:
      return "rsa_pss_sha256"
    case .ecdsaSignatureMessageX962SHA256:
      return "ecdsa_x962_sha256"
    }
  }
}

protocol X509ChallengeSigningKey {
  func isAlgorithmSupported(_ algorithm: X509SignatureAlgorithm) -> Bool
  func sign(challenge: Data, algorithm: X509SignatureAlgorithm) throws -> Data
}

private struct AppleX509ChallengeSigningKey: X509ChallengeSigningKey {
  let key: SecKey

  func isAlgorithmSupported(_ algorithm: X509SignatureAlgorithm) -> Bool {
    SecKeyIsAlgorithmSupported(key, .sign, algorithm.securityAlgorithm)
  }

  func sign(challenge: Data, algorithm: X509SignatureAlgorithm) throws -> Data {
    var error: Unmanaged<CFError>?

    // SecKeyCreateSignature performs the operation inside the keychain-backed key object. For
    // Secure Enclave or non-exportable keys this is the point where the key is used, but it is not
    // copied into process memory.
    guard
      let signature = SecKeyCreateSignature(
        key,
        algorithm.securityAlgorithm,
        challenge as CFData,
        &error
      ) as Data?
    else {
      let message =
        error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String }
        ?? "unknown error"
      throw X509ClientAuthChallengeSigner.Error.signatureCreationFailed(message)
    }

    return signature
  }
}

private func loadX509ClientAuthIdentityRecords() throws -> [X509IdentityRecord] {
  #if os(macOS)
    var records = try loadX509ClientAuthIdentityRecords(
      queryOverrides: [:],
      querySource: "default"
    )

    if let systemKeychain = systemKeychain() {
      records.append(
        contentsOf: try loadX509ClientAuthIdentityRecords(
          queryOverrides: [kSecMatchSearchList: [systemKeychain]],
          querySource: "system"
        )
      )
    } else {
      Log.debug("Device trust signer: unable to open System keychain for explicit identity query")
    }

    return records.deduplicatedByCertificateDER()
  #else
    return try loadX509ClientAuthIdentityRecords(queryOverrides: [:], querySource: "default")
  #endif
}

private func loadX509ClientAuthIdentityRecords(
  queryOverrides: [CFString: Any],
  querySource: String
) throws -> [X509IdentityRecord] {
  // Query identities, not certificates. A certificate alone can be public-only; an identity means
  // the system believes there is corresponding private-key material available.
  //
  // kSecUseAuthenticationUISkip is important for the Network Extension path: if a key cannot be
  // used without UI, we skip it rather than causing a surprise auth prompt from the tunnel process.
  var query: [CFString: Any] = [
    kSecClass: kSecClassIdentity,
    kSecReturnRef: true,
    kSecMatchLimit: kSecMatchLimitAll,
    kSecUseAuthenticationUI: kSecUseAuthenticationUISkip,
  ]
  query.merge(queryOverrides) { _, new in new }

  var result: CFTypeRef?
  let status = SecItemCopyMatching(query as CFDictionary, &result)

  switch status {
  case errSecSuccess:
    break
  case errSecItemNotFound:
    Log.debug("Device trust signer: identity query source=\(querySource) found no identities")
    return []
  default:
    Log.debug(
      "Device trust signer: identity query source=\(querySource) failed status=\(statusMessage(status))"
    )
    throw X509ClientAuthChallengeSigner.Error.identityQueryFailed(status)
  }

  let identities = unwrapIdentities(result)
  Log.debug(
    "Device trust signer: identity query source=\(querySource) returned \(identities.count) identity reference(s)"
  )

  return try identities.map { identity in
    var certificate: SecCertificate?
    let certificateStatus = SecIdentityCopyCertificate(identity, &certificate)
    guard certificateStatus == errSecSuccess, let certificate else {
      throw X509ClientAuthChallengeSigner.Error.identityCertificateCopyFailed(certificateStatus)
    }

    return X509IdentityRecord(
      certificateDER: SecCertificateCopyData(certificate) as Data,
      metadata: x509CertificateMetadata(for: certificate),
      copySigningKey: {
        // Copying the SecKey reference does not export private key bytes. It only gives us a handle
        // that Security.framework can use for signing if policy allows this process to access it.
        var privateKey: SecKey?
        let privateKeyStatus = SecIdentityCopyPrivateKey(identity, &privateKey)

        if privateKeyStatus == errSecSuccess, let privateKey {
          return AppleX509ChallengeSigningKey(key: privateKey)
        }

        Log.debug(
          "Device trust signer: private key copy failed status=\(statusMessage(privateKeyStatus))"
        )
        return nil
      }
    )
  }
}

#if os(macOS)
  private func systemKeychain() -> SecKeychain? {
    var keychain: SecKeychain?
    let status = SecKeychainOpen("/Library/Keychains/System.keychain", &keychain)

    if status != errSecSuccess {
      Log.debug("Device trust signer: System keychain open failed status=\(statusMessage(status))")
    }

    return keychain
  }
#endif

private func unwrapIdentities(_ result: CFTypeRef?) -> [SecIdentity] {
  guard let result else { return [] }

  // SecItemCopyMatching returns either one object or an array depending on kSecMatchLimit. Validate
  // Core Foundation type IDs before downcasting so a malformed or unexpected result cannot crash us.
  if CFGetTypeID(result) == SecIdentityGetTypeID() {
    return [unsafeDowncast(result, to: SecIdentity.self)]
  }

  if CFGetTypeID(result) == CFArrayGetTypeID(), let array = result as? [Any] {
    return array.compactMap(secIdentity(from:))
  }

  return []
}

private func secIdentity(from value: Any) -> SecIdentity? {
  let cfValue = value as CFTypeRef
  guard CFGetTypeID(cfValue) == SecIdentityGetTypeID() else {
    return nil
  }

  return unsafeDowncast(cfValue, to: SecIdentity.self)
}

private func statusMessage(_ status: OSStatus) -> String {
  SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
}

extension Array where Element == X509IdentityRecord {
  fileprivate func deduplicatedByCertificateDER() -> [X509IdentityRecord] {
    var seen = Set<Data>()

    return filter { record in
      seen.insert(record.certificateDER).inserted
    }
  }
}

extension Data {
  fileprivate func sha256HexString() -> String {
    SHA256.hash(data: self)
      .map { String(format: "%02x", $0) }
      .joined()
  }
}
