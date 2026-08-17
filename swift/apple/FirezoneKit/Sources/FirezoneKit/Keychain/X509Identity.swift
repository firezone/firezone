//
//  X509Identity.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import CryptoKit
import Foundation
import Security

private func securityErrorDescription(_ status: OSStatus) -> String {
  (SecCopyErrorMessageString(status, nil) as String?) ?? "OSStatus \(status)"
}

public struct X509DetailField: Sendable {
  public let label: String
  public let value: String

  public init(label: String, value: String) {
    self.label = label
    self.value = value
  }
}

public struct X509DetailSection: Sendable {
  public let title: String
  public let fields: [X509DetailField]

  public init(title: String, fields: [X509DetailField]) {
    self.title = title
    self.fields = fields
  }
}

public struct X509IdentityDetails: Sendable {
  public let summary: String
  public let sections: [X509DetailSection]

  public init(summary: String, sections: [X509DetailSection]) {
    self.summary = summary
    self.sections = sections
  }

  /// Plain-text rendering shared by command-line diagnostics and tests.
  public var textDescription: String {
    var lines = [summary]

    for section in sections {
      lines.append("")
      lines.append("[\(section.title)]")

      for field in section.fields {
        lines.append("\(field.label):")
        lines.append(
          contentsOf: field.value.split(separator: "\n", omittingEmptySubsequences: false)
            .map { "  \($0)" }
        )
      }
    }

    return lines.joined(separator: "\n") + "\n"
  }
}

public enum X509IdentityError: LocalizedError {
  case keychainLookup(OSStatus)
  case invalidKeychainItem
  case copyCertificate(OSStatus)
  case copyPrivateKey(OSStatus)
  case unexpectedCommonName(String?)
  case unsupportedPrivateKey(type: String, size: Int?)
  case signingFailed(String)

  public var errorDescription: String? {
    switch self {
    case .keychainLookup(let status):
      return
        "The VPN certificate could not be loaded from the keychain (\(securityErrorDescription(status)))."
    case .invalidKeychainItem:
      return "The VPN certificate reference did not resolve to an identity."
    case .copyCertificate(let status):
      return
        "The leaf certificate could not be read from the VPN identity (\(securityErrorDescription(status)))."
    case .copyPrivateKey(let status):
      return
        "The private key could not be opened for mutual TLS (\(securityErrorDescription(status)))."
    case .unexpectedCommonName(let commonName):
      return
        "The VPN identity has common name '\(commonName ?? "Unavailable")'; expected 'dev.firezone.device-trust'."
    case .unsupportedPrivateKey(let type, let size):
      let sizeDescription = size.map { ", \($0) bits" } ?? ""
      return "The VPN identity uses an unsupported private key (\(type)\(sizeDescription))."
    case .signingFailed(let message):
      return "The VPN identity could not sign the mutual-TLS handshake (\(message))."
    }
  }
}

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
}

/// User authentication attributes carried by a managed client certificate.
public struct X509UserIdentity: Equatable, Sendable {
  public let email: String
  public let accountId: String

  public init(email: String, accountId: String) {
    self.email = email
    self.accountId = accountId
  }
}

public final class X509ClientTlsIdentity: @unchecked Sendable {
  private let certificates: [Data]
  private let privateKey: SecKey
  private let schemes: [X509SignatureScheme]
  public let mdmDeviceId: String?
  public let userIdentity: X509UserIdentity?

  fileprivate init(
    certificates: [Data],
    privateKey: SecKey,
    mdmDeviceId: String?,
    userIdentity: X509UserIdentity?
  ) throws {
    self.certificates = certificates
    self.privateKey = privateKey
    self.schemes = try X509Identity.supportedSignatureSchemes(privateKey: privateKey)
    self.mdmDeviceId = mdmDeviceId
    self.userIdentity = userIdentity
  }

  public func certificateChain() throws -> [Data] {
    certificates
  }

  public func supportedSignatureSchemes() -> [X509SignatureScheme] {
    schemes
  }

  public func sign(scheme: X509SignatureScheme, message: Data) throws -> Data {
    let algorithm = try X509Identity.signingAlgorithm(scheme: scheme)
    guard SecKeyIsAlgorithmSupported(privateKey, .sign, algorithm) else {
      throw X509IdentityError.signingFailed("signature scheme \(scheme) is unsupported")
    }

    var signingError: Unmanaged<CFError>?
    guard
      let signature = SecKeyCreateSignature(
        privateKey,
        algorithm,
        message as CFData,
        &signingError
      ) as Data?
    else {
      let message = signingFailureMessage(signingError?.takeRetainedValue())
      throw X509IdentityError.signingFailed(message)
    }
    return signature
  }

  private func signingFailureMessage(_ error: CFError?) -> String {
    guard let error else { return "unknown error" }
    guard CFErrorGetCode(error) == CFIndex(errSecInteractionNotAllowed) else {
      return error.localizedDescription
    }

    Log.error(
      "X.509 private-key signing was denied because user interaction is unavailable "
        + "(status=\(CFErrorGetCode(error)), description=\(error.localizedDescription))"
    )
    return SessionAuthenticationMode.unusableX509PrivateKeyMessage
  }
}

/// Reads and uses the identity referenced by `NEVPNProtocol.identityReference`.
/// Private-key bytes are never exported; signing happens inside Security.framework.
public enum X509Identity {
  private static let expectedSubjectCommonName = "dev.firezone.device-trust"

  public static func clientTlsIdentity(
    persistentReference: Data?
  ) throws -> X509ClientTlsIdentity? {
    guard let persistentReference else {
      Log.info("The VPN configuration has no mutual-TLS identity reference")
      return nil
    }

    Log.info(
      "Loading VPN identity for mutual TLS (referenceBytes=\(persistentReference.count))")
    let identity = try loadIdentity(persistentReference: persistentReference)
    let certificate = try copyCertificate(identity: identity)
    let actualCommonName = commonName(certificate)
    guard actualCommonName == expectedSubjectCommonName else {
      throw X509IdentityError.unexpectedCommonName(actualCommonName)
    }

    let privateKey = try copyPrivateKey(identity: identity)
    let certificateData = SecCertificateCopyData(certificate) as Data
    let certificates = copyCertificateChain(leaf: certificate)
    let mdmDeviceId = mdmDeviceId(certificateData: certificateData)
    let userIdentity = userIdentity(certificateData: certificateData)
    Log.info(
      "Loaded VPN identity for mutual TLS "
        + "(certificates=\(certificates.count), fingerprint=\(sha256Hex(certificateData)), "
        + "mdmDeviceId=\(mdmDeviceId ?? "Unavailable"), "
        + "certificateUserAuth=\(userIdentity == nil ? "unavailable" : "available"))"
    )

    return try X509ClientTlsIdentity(
      certificates: certificates,
      privateKey: privateKey,
      mdmDeviceId: mdmDeviceId,
      userIdentity: userIdentity
    )
  }

  /// Returns every certificate, identity-reference, and key attribute exposed by
  /// public Security.framework APIs on the current platform.
  public static func details(persistentReference: Data?) throws -> X509IdentityDetails {
    guard let persistentReference else {
      return X509IdentityDetails(
        summary: "No X.509 identity is configured for this VPN configuration.",
        sections: [
          X509DetailSection(
            title: "VPN Configuration",
            fields: [X509DetailField(label: "Identity Reference", value: "Not configured")]
          )
        ]
      )
    }

    var sections = [
      X509DetailSection(
        title: "VPN Configuration",
        fields: dataFields(label: "Identity Persistent Reference", data: persistentReference)
      )
    ]

    let identity = try loadIdentity(persistentReference: persistentReference)
    do {
      let keychainAttributes = try copyKeychainAttributes(
        persistentReference: persistentReference)
      sections.append(
        X509DetailSection(
          title: "Keychain Identity Attributes", fields: fields(keychainAttributes))
      )
    } catch {
      sections.append(diagnosticErrorSection(title: "Keychain Identity Attributes", error: error))
    }

    let certificate = try copyCertificate(identity: identity)
    let certificateData = SecCertificateCopyData(certificate) as Data
    var certificateFields = [
      X509DetailField(
        label: "Security Description", value: String(describing: certificate)),
      X509DetailField(
        label: "Subject Summary",
        value: (SecCertificateCopySubjectSummary(certificate) as String?) ?? "Unavailable"),
      X509DetailField(
        label: "SHA-256 Fingerprint", value: sha256Hex(certificateData)),
      X509DetailField(label: "DER Byte Count", value: String(certificateData.count)),
      X509DetailField(label: "DER (Base64)", value: certificateData.base64EncodedString()),
      X509DetailField(label: "PEM", value: pem(certificateData)),
    ]

    if let normalizedSubject = SecCertificateCopyNormalizedSubjectSequence(certificate) as Data? {
      certificateFields.append(
        X509DetailField(
          label: "Normalized Subject (DER)", value: describeData(normalizedSubject)))
    }
    if let normalizedIssuer = SecCertificateCopyNormalizedIssuerSequence(certificate) as Data? {
      certificateFields.append(
        X509DetailField(
          label: "Normalized Issuer (DER)", value: describeData(normalizedIssuer)))
    }

    let subjectAlternativeNameFields = subjectAlternativeNameFields(
      certificateData: certificateData)
    let firezoneAttributeFields = firezoneAttributeFields(certificateData: certificateData)

    if !firezoneAttributeFields.isEmpty {
      sections.insert(
        X509DetailSection(title: "Identity Attributes", fields: firezoneAttributeFields),
        at: 0
      )
    }

    var subjectFieldInsertionIndex = 2
    if let commonName = commonName(certificate) {
      certificateFields.insert(X509DetailField(label: "Common Name", value: commonName), at: 2)
      subjectFieldInsertionIndex += 1
    }
    certificateFields.insert(
      X509DetailField(
        label: "Subject Alternative Name Count",
        value: String(subjectAlternativeNameFields.count)
      ),
      at: subjectFieldInsertionIndex)
    let emailAddresses = emailAddresses(certificate)
    if !emailAddresses.isEmpty {
      certificateFields.append(
        X509DetailField(label: "Email Addresses", value: emailAddresses.joined(separator: "\n")))
    }
    if let serialNumber = serialNumber(certificate) {
      certificateFields.append(
        X509DetailField(label: "Serial Number", value: hex(serialNumber, separator: ":")))
    }
    sections.append(X509DetailSection(title: "Leaf Certificate", fields: certificateFields))
    sections.append(
      X509DetailSection(
        title: "Subject Alternative Names (SAN)",
        fields: subjectAlternativeNameFields.isEmpty
          ? [X509DetailField(label: "Values", value: "None")]
          : subjectAlternativeNameFields
      )
    )

    #if os(macOS)
      sections.append(
        X509DetailSection(
          title: "Parsed Certificate Values (macOS Security.framework)",
          fields: parsedCertificateFields(certificate)
        )
      )
    #endif

    if let publicKey = SecCertificateCopyKey(certificate),
      let attributes = SecKeyCopyAttributes(publicKey) as? [CFString: Any]
    {
      sections.append(X509DetailSection(title: "Public Key Attributes", fields: fields(attributes)))
    }

    do {
      let privateKey = try copyPrivateKey(identity: identity)
      if let attributes = SecKeyCopyAttributes(privateKey) as? [CFString: Any] {
        var privateKeyFields = fields(attributes)
        privateKeyFields.append(
          X509DetailField(
            label: "Private Key Export",
            value: "Not attempted; device-attestation signing occurs inside Security.framework."
          )
        )
        sections.append(
          X509DetailSection(title: "Private Key Attributes", fields: privateKeyFields))
      } else {
        sections.append(
          X509DetailSection(
            title: "Private Key Attributes",
            fields: [X509DetailField(label: "Attributes", value: "Unavailable")]
          )
        )
      }
    } catch {
      sections.append(diagnosticErrorSection(title: "Private Key Attributes", error: error))
    }

    Log.info(
      "Loaded X.509 diagnostics for VPN identity "
        + "(sections=\(sections.count), fingerprint=\(sha256Hex(certificateData)))"
    )
    return X509IdentityDetails(
      summary: "The VPN configuration identity reference resolved successfully.",
      sections: sections
    )
  }

  private static func loadIdentity(persistentReference: Data) throws -> SecIdentity {
    let query: [CFString: Any] = [
      // An identity is a virtual keychain item backed by a certificate and its
      // private key. Without an explicit class, macOS may resolve an identity's
      // persistent reference to the certificate half instead.
      kSecClass: kSecClassIdentity,
      kSecValuePersistentRef: persistentReference,
      kSecReturnRef: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess else {
      Log.error(
        "Failed to resolve the VPN identity persistent reference as a keychain identity "
          + "(status=\(status), description=\(securityErrorDescription(status)))"
      )
      throw X509IdentityError.keychainLookup(status)
    }
    guard let result, CFGetTypeID(result) == SecIdentityGetTypeID() else {
      let actualType =
        result.map { CFCopyTypeIDDescription(CFGetTypeID($0)) as String }
        ?? "nil"
      Log.error(
        "VPN identity persistent reference returned an unexpected keychain item "
          + "(type=\(actualType))"
      )
      throw X509IdentityError.invalidKeychainItem
    }

    // The runtime type ID check above is the Core Foundation equivalent of a checked cast.
    // swiftlint:disable:next force_cast
    return result as! SecIdentity
  }

  private static func copyKeychainAttributes(persistentReference: Data) throws
    -> [CFString: Any]
  {
    let query: [CFString: Any] = [
      kSecClass: kSecClassIdentity,
      kSecValuePersistentRef: persistentReference,
      kSecReturnAttributes: true,
      kSecMatchLimit: kSecMatchLimitOne,
    ]
    var result: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &result)
    guard status == errSecSuccess else { throw X509IdentityError.keychainLookup(status) }
    guard let attributes = result as? [CFString: Any] else {
      throw X509IdentityError.invalidKeychainItem
    }
    return attributes
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

  private static func copyCertificateChain(leaf: SecCertificate) -> [Data] {
    var trust: SecTrust?
    let status = SecTrustCreateWithCertificates(leaf, SecPolicyCreateBasicX509(), &trust)
    guard status == errSecSuccess, let trust else {
      return [SecCertificateCopyData(leaf) as Data]
    }

    // Evaluation asks Security.framework to build the chain. A private MDM root
    // may not be trusted for general-purpose evaluation, but the constructed
    // chain is still usable by rustls for the mutual-TLS handshake.
    _ = SecTrustEvaluateWithError(trust, nil)
    let chain = SecTrustCopyCertificateChain(trust) as? [SecCertificate] ?? [leaf]
    return chain.map { SecCertificateCopyData($0) as Data }
  }

  fileprivate static func supportedSignatureSchemes(privateKey: SecKey) throws
    -> [X509SignatureScheme]
  {
    let attributes = SecKeyCopyAttributes(privateKey) as? [CFString: Any]
    let keyType = attributes?[kSecAttrKeyType].map(String.init(describing:)) ?? "unknown"
    let keySize = attributes?[kSecAttrKeySizeInBits] as? Int

    let rsaType = kSecAttrKeyTypeRSA as String
    let ecType = kSecAttrKeyTypeECSECPrimeRandom as String
    let legacyECType = kSecAttrKeyTypeEC as String
    let candidates: [X509SignatureScheme]
    switch keyType {
    case rsaType:
      candidates = [
        .rsaPssSha512, .rsaPssSha384, .rsaPssSha256,
        .rsaPkcs1Sha512, .rsaPkcs1Sha384, .rsaPkcs1Sha256,
      ]
    case ecType, legacyECType:
      switch keySize {
      case 256: candidates = [.ecdsaNistp256Sha256]
      case 384: candidates = [.ecdsaNistp384Sha384]
      case 521: candidates = [.ecdsaNistp521Sha512]
      default: throw X509IdentityError.unsupportedPrivateKey(type: keyType, size: keySize)
      }
    default:
      throw X509IdentityError.unsupportedPrivateKey(type: keyType, size: keySize)
    }

    let supported = candidates.filter {
      guard let algorithm = try? signingAlgorithm(scheme: $0) else { return false }
      return SecKeyIsAlgorithmSupported(privateKey, .sign, algorithm)
    }
    guard !supported.isEmpty else {
      throw unsupportedKeyError(attributes: attributes ?? [:])
    }
    return supported
  }

  fileprivate static func signingAlgorithm(scheme: X509SignatureScheme) throws -> SecKeyAlgorithm {
    switch scheme {
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

  private static func unsupportedKeyError(attributes: [CFString: Any]) -> X509IdentityError {
    let type = attributes[kSecAttrKeyType].map(String.init(describing:)) ?? "unknown"
    let size = attributes[kSecAttrKeySizeInBits] as? Int
    return .unsupportedPrivateKey(type: type, size: size)
  }

  private static func commonName(_ certificate: SecCertificate) -> String? {
    var value: CFString?
    guard SecCertificateCopyCommonName(certificate, &value) == errSecSuccess else { return nil }
    return value as String?
  }

  private static func emailAddresses(_ certificate: SecCertificate) -> [String] {
    var values: CFArray?
    guard SecCertificateCopyEmailAddresses(certificate, &values) == errSecSuccess else { return [] }
    return values as? [String] ?? []
  }

  private static func serialNumber(_ certificate: SecCertificate) -> Data? {
    var error: Unmanaged<CFError>?
    return SecCertificateCopySerialNumberData(certificate, &error) as Data?
  }

  private static func fields(_ attributes: [CFString: Any]) -> [X509DetailField] {
    attributes
      .map { key, value in
        X509DetailField(label: attributeName(key), value: describe(value))
      }
      .sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
  }

  private static func attributeName(_ key: CFString) -> String {
    let names: [String: String] = [
      kSecClass as String: "Class",
      kSecAttrAccessControl as String: "Access Control",
      kSecAttrAccessGroup as String: "Access Group",
      kSecAttrAccessible as String: "Accessible",
      kSecAttrApplicationLabel as String: "Application Label",
      kSecAttrApplicationTag as String: "Application Tag",
      kSecAttrCanDecrypt as String: "Can Decrypt",
      kSecAttrCanDerive as String: "Can Derive",
      kSecAttrCanEncrypt as String: "Can Encrypt",
      kSecAttrCanSign as String: "Can Sign",
      kSecAttrCanUnwrap as String: "Can Unwrap",
      kSecAttrCanVerify as String: "Can Verify",
      kSecAttrCanWrap as String: "Can Wrap",
      kSecAttrCreationDate as String: "Creation Date",
      kSecAttrEffectiveKeySize as String: "Effective Key Size (bits)",
      kSecAttrIsPermanent as String: "Is Permanent",
      kSecAttrIsSensitive as String: "Is Sensitive",
      kSecAttrKeyClass as String: "Key Class",
      kSecAttrKeySizeInBits as String: "Key Size (bits)",
      kSecAttrKeyType as String: "Key Type",
      kSecAttrLabel as String: "Label",
      kSecAttrModificationDate as String: "Modification Date",
      kSecAttrSynchronizable as String: "Synchronizable",
      kSecAttrTokenID as String: "Token ID",
    ]
    let raw = key as String
    return names[raw].map { "\($0) [\(raw)]" } ?? raw
  }

  private static func dataFields(label: String, data: Data) -> [X509DetailField] {
    [
      X509DetailField(label: "\(label) Byte Count", value: String(data.count)),
      X509DetailField(label: "\(label) (Hex)", value: hex(data, separator: ":")),
      X509DetailField(label: "\(label) (Base64)", value: data.base64EncodedString()),
    ]
  }

  private static func diagnosticErrorSection(title: String, error: Error) -> X509DetailSection {
    X509DetailSection(
      title: title,
      fields: [X509DetailField(label: "Read Error", value: error.localizedDescription)]
    )
  }

  private static func describe(_ value: Any, indentation: String = "") -> String {
    if let data = value as? Data { return describeData(data) }
    if let date = value as? Date { return ISO8601DateFormatter().string(from: date) }
    if let array = value as? [Any] {
      return array.enumerated().map { index, child in
        "\(indentation)[\(index)] \(describe(child, indentation: indentation + "  "))"
      }.joined(separator: "\n")
    }
    if let dictionary = value as? [AnyHashable: Any] {
      return dictionary.map { key, child in
        "\(indentation)\(key): \(describe(child, indentation: indentation + "  "))"
      }.sorted().joined(separator: "\n")
    }
    return String(describing: value)
  }

  private static func describeData(_ data: Data) -> String {
    "Hex: \(hex(data, separator: ":"))\nBase64: \(data.base64EncodedString())"
  }

  private static func hex(_ data: Data, separator: String = "") -> String {
    data.map { String(format: "%02X", $0) }.joined(separator: separator)
  }

  private static func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02X", $0) }.joined(separator: ":")
  }

  private static func pem(_ data: Data) -> String {
    let encoded = data.base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
    return "-----BEGIN CERTIFICATE-----\n\(encoded)-----END CERTIFICATE-----"
  }

  #if os(macOS)
    private static func parsedCertificateFields(_ certificate: SecCertificate) -> [X509DetailField]
    {
      var error: Unmanaged<CFError>?
      guard let values = SecCertificateCopyValues(certificate, nil, &error) as? [String: Any]
      else {
        let message = error?.takeRetainedValue().localizedDescription ?? "unknown error"
        return [X509DetailField(label: "Parse Error", value: message)]
      }

      return values.map { oid, value in
        X509DetailField(label: oid, value: describe(value))
      }.sorted { $0.label.localizedStandardCompare($1.label) == .orderedAscending }
    }
  #endif
}
