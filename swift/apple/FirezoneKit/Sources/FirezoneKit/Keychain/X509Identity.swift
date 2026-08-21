//
//  X509Identity.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//
//  Reads the client identity that MDM installs on the VPN configuration and signs
//  mutual-TLS handshakes with it. Private-key bytes are never exported; every
//  signature is produced inside Security.framework.

import Foundation
import Security

/// The TLS handshake signature schemes a platform-held key can sign with.
///
/// Mirrors `TlsSignatureScheme` of the connlib bindings. FirezoneKit is a Swift package
/// and cannot see those bindings, which are compiled into the app and Network Extension
/// targets, so the Network Extension translates between the two.
public enum X509SignatureScheme: Sendable {
  case rsaPkcs1Sha256
  case rsaPkcs1Sha384
  case rsaPkcs1Sha512
  case rsaPssSha256
  case rsaPssSha384
  case rsaPssSha512
  case ecdsaNistp256Sha256
  case ecdsaNistp384Sha384
  case ecdsaNistp521Sha512

  var securityAlgorithm: SecKeyAlgorithm {
    switch self {
    case .rsaPkcs1Sha256: return .rsaSignatureMessagePKCS1v15SHA256
    case .rsaPkcs1Sha384: return .rsaSignatureMessagePKCS1v15SHA384
    case .rsaPkcs1Sha512: return .rsaSignatureMessagePKCS1v15SHA512
    case .rsaPssSha256: return .rsaSignatureMessagePSSSHA256
    case .rsaPssSha384: return .rsaSignatureMessagePSSSHA384
    case .rsaPssSha512: return .rsaSignatureMessagePSSSHA512
    case .ecdsaNistp256Sha256: return .ecdsaSignatureMessageX962SHA256
    case .ecdsaNistp384Sha384: return .ecdsaSignatureMessageX962SHA384
    case .ecdsaNistp521Sha512: return .ecdsaSignatureMessageX962SHA512
    }
  }
}

public enum X509IdentityError: LocalizedError {
  case keychainLookup(OSStatus)
  case notAnIdentity
  case copyCertificate(OSStatus)
  case copyPrivateKey(OSStatus)
  case unsupportedPrivateKey(type: String, sizeInBits: Int?)
  case signingFailed(String)

  public var errorDescription: String? {
    switch self {
    case .keychainLookup(let status):
      return "The VPN certificate could not be read from the keychain (\(Self.describe(status)))."
    case .notAnIdentity:
      return "The VPN certificate reference did not resolve to a keychain identity."
    case .copyCertificate(let status):
      return "The certificate could not be read from the VPN identity (\(Self.describe(status)))."
    case .copyPrivateKey(let status):
      return "The private key could not be opened for mutual TLS (\(Self.describe(status)))."
    case .unsupportedPrivateKey(let type, let sizeInBits):
      let size = sizeInBits.map { ", \($0) bits" } ?? ""
      return "The VPN identity uses an unsupported private key (\(type)\(size))."
    case .signingFailed(let message):
      return "The VPN identity could not sign the mutual-TLS handshake (\(message))."
    }
  }

  static func describe(_ status: OSStatus) -> String {
    (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
  }
}

/// A certificate chain plus the non-exportable key that signs for it.
///
/// `SecKey` and `SecCertificate` operations are thread-safe, and this type only ever
/// reads from them, so it is safe to hand to connlib's TLS stack on any thread.
public final class X509ClientIdentity: @unchecked Sendable {
  /// DER-encoded certificates, end-entity certificate first.
  public let certificateChain: [Data]
  /// Signature schemes the key can sign with, most preferred first.
  public let signatureSchemes: [X509SignatureScheme]

  private let privateKey: SecKey

  init(certificateChain: [Data], privateKey: SecKey) throws {
    self.certificateChain = certificateChain
    self.privateKey = privateKey
    self.signatureSchemes = try X509Identity.signatureSchemes(for: privateKey)
  }

  /// Signs the unhashed handshake message, hashing and padding inside the keychain.
  public func sign(scheme: X509SignatureScheme, message: Data) throws -> Data {
    let algorithm = scheme.securityAlgorithm

    guard SecKeyIsAlgorithmSupported(privateKey, .sign, algorithm) else {
      throw X509IdentityError.signingFailed("the key cannot sign with \(scheme)")
    }

    var error: Unmanaged<CFError>?
    guard let signature = SecKeyCreateSignature(privateKey, algorithm, message as CFData, &error)
    else {
      throw X509IdentityError.signingFailed(Self.describe(error?.takeRetainedValue()))
    }

    return signature as Data
  }

  private static func describe(_ error: CFError?) -> String {
    guard let error else { return "unknown error" }

    guard CFErrorGetCode(error) == CFIndex(errSecInteractionNotAllowed) else {
      return error.localizedDescription
    }

    // MDM can install a VPN identity whose key requires a user prompt. The Network
    // Extension has no UI, so the handshake can never succeed until an administrator
    // allows all apps to use the key.
    return
      "the private key requires user interaction; its access control must allow all apps to use it"
  }
}

/// Loads the identity referenced by `NEVPNProtocol.identityReference`.
public enum X509Identity {
  /// PSS first: TLS 1.3 accepts only PSS, and TLS 1.2 accepts either padding.
  private static let rsaSchemes: [X509SignatureScheme] = [
    .rsaPssSha512, .rsaPssSha384, .rsaPssSha256, .rsaPkcs1Sha512, .rsaPkcs1Sha384, .rsaPkcs1Sha256,
  ]

  // Bridged here rather than in the `case` patterns below, where `as String` would parse
  // as a cast of the value being matched instead of a bridge of the constant.
  private static let rsaKeyType = kSecAttrKeyTypeRSA as String
  private static let ellipticCurveKeyType = kSecAttrKeyTypeECSECPrimeRandom as String

  /// Resolves the persistent keychain reference MDM stored on the VPN configuration.
  ///
  /// The reference is used verbatim rather than searching the keychain for a matching
  /// certificate: a broad query can pick an unrelated identity that happens to look right.
  public static func load(persistentReference: Data?) throws -> X509ClientIdentity? {
    guard let persistentReference else {
      Log.info("The VPN configuration carries no mutual-TLS identity reference")
      return nil
    }

    let identity = try loadIdentity(persistentReference: persistentReference)
    let certificate = try copyCertificate(identity: identity)
    let privateKey = try copyPrivateKey(identity: identity)
    let chain = certificateChain(leaf: certificate)

    Log.info("Loaded the VPN mutual-TLS identity (certificates=\(chain.count))")

    return try X509ClientIdentity(certificateChain: chain, privateKey: privateKey)
  }

  /// The DER-encoded end-entity certificate of the configured identity, for diagnostics.
  public static func leafCertificate(persistentReference: Data?) throws -> Data? {
    guard let persistentReference else { return nil }

    let identity = try loadIdentity(persistentReference: persistentReference)
    let certificate = try copyCertificate(identity: identity)

    return SecCertificateCopyData(certificate) as Data
  }

  private static func loadIdentity(persistentReference: Data) throws -> SecIdentity {
    // An identity is a virtual keychain item backed by a certificate and its private
    // key. Without an explicit class, macOS can resolve the persistent reference to
    // the certificate half instead.
    let query: [CFString: Any] = [
      kSecClass: kSecClassIdentity,
      kSecValuePersistentRef: persistentReference,
      kSecReturnRef: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ]

    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)

    guard status == errSecSuccess else {
      Log.error(
        "Could not resolve the VPN identity reference: \(X509IdentityError.describe(status))")
      throw X509IdentityError.keychainLookup(status)
    }

    guard let result, CFGetTypeID(result) == SecIdentityGetTypeID() else {
      Log.error("The VPN identity reference resolved to something other than an identity")
      throw X509IdentityError.notAnIdentity
    }

    // The runtime type check above is the Core Foundation equivalent of a checked cast.
    // swiftlint:disable:next force_cast
    return result as! SecIdentity
  }

  private static func copyCertificate(identity: SecIdentity) throws -> SecCertificate {
    var certificate: SecCertificate?
    let status = SecIdentityCopyCertificate(identity, &certificate)

    guard status == errSecSuccess, let certificate else {
      throw X509IdentityError.copyCertificate(status)
    }

    return certificate
  }

  private static func copyPrivateKey(identity: SecIdentity) throws -> SecKey {
    var privateKey: SecKey?
    let status = SecIdentityCopyPrivateKey(identity, &privateKey)

    guard status == errSecSuccess, let privateKey else {
      throw X509IdentityError.copyPrivateKey(status)
    }

    return privateKey
  }

  /// Builds the chain to present, falling back to the end-entity certificate alone.
  ///
  /// A private MDM root is rarely trusted for general-purpose evaluation, so the result
  /// of the evaluation is ignored: it only exists to make Security.framework assemble the
  /// intermediates. Network fetching stays off so a tunnel start cannot block on it.
  private static func certificateChain(leaf: SecCertificate) -> [Data] {
    var trust: SecTrust?
    let status = SecTrustCreateWithCertificates(leaf, SecPolicyCreateBasicX509(), &trust)

    guard status == errSecSuccess, let trust else {
      return [SecCertificateCopyData(leaf) as Data]
    }

    _ = SecTrustSetNetworkFetchAllowed(trust, false)
    _ = SecTrustEvaluateWithError(trust, nil)

    let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? [leaf]

    return chain.map { SecCertificateCopyData($0) as Data }
  }

  /// The schemes the key advertises, ordered by what we would rather use.
  ///
  /// All of them belong to the same key algorithm, which is what connlib requires.
  static func signatureSchemes(for privateKey: SecKey) throws -> [X509SignatureScheme] {
    let attributes = SecKeyCopyAttributes(privateKey) as? [CFString: Any] ?? [:]
    let keyType = attributes[kSecAttrKeyType].map(String.init(describing:)) ?? "unknown"
    let sizeInBits = attributes[kSecAttrKeySizeInBits] as? Int

    let candidates: [X509SignatureScheme]
    switch keyType {
    case Self.rsaKeyType:
      candidates = Self.rsaSchemes
    case Self.ellipticCurveKeyType:
      switch sizeInBits {
      case 256: candidates = [.ecdsaNistp256Sha256]
      case 384: candidates = [.ecdsaNistp384Sha384]
      case 521: candidates = [.ecdsaNistp521Sha512]
      default:
        throw X509IdentityError.unsupportedPrivateKey(type: keyType, sizeInBits: sizeInBits)
      }
    default:
      throw X509IdentityError.unsupportedPrivateKey(type: keyType, sizeInBits: sizeInBits)
    }

    let supported = candidates.filter {
      SecKeyIsAlgorithmSupported(privateKey, .sign, $0.securityAlgorithm)
    }

    guard !supported.isEmpty else {
      throw X509IdentityError.unsupportedPrivateKey(type: keyType, sizeInBits: sizeInBits)
    }

    return supported
  }
}
