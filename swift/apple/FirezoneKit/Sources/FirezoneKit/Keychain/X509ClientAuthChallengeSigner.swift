//
//  X509ClientAuthChallengeSigner.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
import Security

public struct X509ClientAuthChallengeSigner {
  public struct SignedChallenge: Codable, Equatable, Sendable {
    public let signedChallengeBase64: String
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
    let matches = identities.compactMap { identity -> SignableX509Identity? in
      guard
        X509CertificatePolicy.matchesClientAuthIdentity(
          identity.metadata,
          subjectCommonName: subjectCommonName,
          now: now
        )
      else {
        return nil
      }
      guard let signingKey = identity.copySigningKey() else {
        return nil
      }
      guard let algorithm = chooseSignatureAlgorithm(for: signingKey) else {
        return nil
      }

      return SignableX509Identity(
        record: identity,
        signingKey: signingKey,
        algorithm: algorithm
      )
    }
    .sorted(by: isPreferredSignableIdentity(_:over:))

    return try matches.map { match in
      let signature = try match.signingKey.sign(challenge: nonce, algorithm: match.algorithm)

      return SignedChallenge(
        signedChallengeBase64: signature.base64EncodedString(),
        leafCertificateDERBase64: match.record.certificateDER.base64EncodedString()
      )
    }
  }

  private func chooseSignatureAlgorithm(for signingKey: any X509ChallengeSigningKey)
    -> X509SignatureAlgorithm?
  {
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
    guard
      let signature = SecKeyCreateSignature(
        key,
        algorithm.securityAlgorithm,
        challenge as CFData,
        &error
      ) as Data?
    else {
      let message = error.map { CFErrorCopyDescription($0.takeRetainedValue()) as String }
        ?? "unknown error"
      throw X509ClientAuthChallengeSigner.Error.signatureCreationFailed(message)
    }

    return signature
  }
}

private func loadX509ClientAuthIdentityRecords() throws -> [X509IdentityRecord] {
  let query: [CFString: Any] = [
    kSecClass: kSecClassIdentity,
    kSecReturnRef: true,
    kSecMatchLimit: kSecMatchLimitAll,
    kSecUseAuthenticationUI: kSecUseAuthenticationUISkip,
  ]

  var result: CFTypeRef?
  let status = SecItemCopyMatching(query as CFDictionary, &result)

  switch status {
  case errSecSuccess:
    break
  case errSecItemNotFound:
    return []
  default:
    throw X509ClientAuthChallengeSigner.Error.identityQueryFailed(status)
  }

  return try unwrapIdentities(result).map { identity in
    var certificate: SecCertificate?
    let certificateStatus = SecIdentityCopyCertificate(identity, &certificate)
    guard certificateStatus == errSecSuccess, let certificate else {
      throw X509ClientAuthChallengeSigner.Error.identityCertificateCopyFailed(certificateStatus)
    }

    return X509IdentityRecord(
      certificateDER: SecCertificateCopyData(certificate) as Data,
      metadata: x509CertificateMetadata(for: certificate),
      copySigningKey: {
        var privateKey: SecKey?
        let privateKeyStatus = SecIdentityCopyPrivateKey(identity, &privateKey)

        if privateKeyStatus == errSecSuccess, let privateKey {
          return AppleX509ChallengeSigningKey(key: privateKey)
        }

        return nil
      }
    )
  }
}

func x509CertificateMetadata(for certificate: SecCertificate) -> X509CertificateMetadata {
  var commonName: CFString?
  SecCertificateCopyCommonName(certificate, &commonName)
  let subjectCommonName =
    commonName as String? ?? (SecCertificateCopySubjectSummary(certificate) as String? ?? "<unknown>")

  let keys = [
    kSecOIDSubjectAltName,
    kSecOIDExtendedKeyUsage,
    kSecOIDX509V1ValidityNotBefore,
    kSecOIDX509V1ValidityNotAfter,
  ] as CFArray

  let values = SecCertificateCopyValues(certificate, keys, nil) as NSDictionary? ?? [:]

  let sanValues = propertyEntries(values: values, oid: kSecOIDSubjectAltName)
    .compactMap { entry -> String? in
      let label = propertyLabel(entry)
      guard label == "URI" || label == "DNS" || label == "Email Address" || label == "UPN" else {
        return nil
      }

      return propertyStringValue(entry)
    }

  let extendedKeyUsageValues = propertyStrings(values: values, oid: kSecOIDExtendedKeyUsage)

  return X509CertificateMetadata(
    subjectCommonName: subjectCommonName,
    sanValues: sanValues,
    extendedKeyUsageValues: extendedKeyUsageValues,
    notBefore: propertyDateValue(values: values, oid: kSecOIDX509V1ValidityNotBefore),
    notAfter: propertyDateValue(values: values, oid: kSecOIDX509V1ValidityNotAfter)
  )
}

private func unwrapIdentities(_ result: CFTypeRef?) -> [SecIdentity] {
  if let identities = result as? [SecIdentity] {
    return identities
  }

  if let array = result as? [Any] {
    return array.map { $0 as! SecIdentity }
  }

  if let result {
    return [result as! SecIdentity]
  }

  return []
}

private func propertyDictionary(values: NSDictionary, oid: CFString) -> NSDictionary? {
  (values[oid] as? NSDictionary) ?? (values[oid as String] as? NSDictionary)
}

private func propertyEntries(values: NSDictionary, oid: CFString) -> [NSDictionary] {
  guard let outer = propertyDictionary(values: values, oid: oid) else {
    return []
  }

  return propertyEntries(from: propertyValue(outer))
}

private func propertyEntries(from rawValue: Any?) -> [NSDictionary] {
  if let entries = rawValue as? [NSDictionary] {
    return entries
  }
  if let entries = rawValue as? [Any] {
    return entries.compactMap { $0 as? NSDictionary }
  }
  if let entry = rawValue as? NSDictionary {
    return [entry]
  }

  return []
}

private func propertyStrings(values: NSDictionary, oid: CFString) -> [String] {
  guard let outer = propertyDictionary(values: values, oid: oid) else {
    return []
  }

  return propertyStrings(from: outer).reduce(into: []) { uniqueStrings, string in
    guard !uniqueStrings.contains(string) else { return }
    uniqueStrings.append(string)
  }
}

private func propertyStrings(from rawValue: Any?) -> [String] {
  switch rawValue {
  case let entry as NSDictionary:
    let values = [propertyLabel(entry), propertyStringValue(entry)].compactMap(\.self)
    return values + propertyStrings(from: propertyValue(entry))

  case let values as [Any]:
    return values.flatMap(propertyStrings(from:))

  case let value as String:
    return [value]

  case let value as URL:
    return [value.absoluteString]

  case let value as NSURL:
    return value.absoluteString.map { [$0] } ?? []

  case let value as Data:
    return objectIdentifierString(from: value).map { [$0] } ?? []

  case let value as NSData:
    return objectIdentifierString(from: value as Data).map { [$0] } ?? []

  default:
    return []
  }
}

private func objectIdentifierString(from data: Data) -> String? {
  guard let firstByte = data.first else {
    return nil
  }

  let firstValue = Int(firstByte)
  let firstComponent = min(firstValue / 40, 2)
  let secondComponent = firstValue - (firstComponent * 40)
  var components = [firstComponent, secondComponent]
  var currentComponent = 0

  for byte in data.dropFirst() {
    currentComponent = (currentComponent << 7) | Int(byte & 0x7f)
    if byte & 0x80 == 0 {
      components.append(currentComponent)
      currentComponent = 0
    }
  }

  guard currentComponent == 0 else {
    return nil
  }

  return components.map(String.init).joined(separator: ".")
}

private func propertyLabel(_ entry: NSDictionary) -> String? {
  (entry[kSecPropertyKeyLabel] as? String) ?? (entry[kSecPropertyKeyLabel as String] as? String)
}

private func propertyStringValue(_ entry: NSDictionary) -> String? {
  if let value = entry[kSecPropertyKeyValue] as? String {
    return value
  }
  if let value = entry[kSecPropertyKeyValue as String] as? String {
    return value
  }
  if let value = entry[kSecPropertyKeyValue] as? URL {
    return value.absoluteString
  }
  if let value = entry[kSecPropertyKeyValue as String] as? URL {
    return value.absoluteString
  }
  if let value = entry[kSecPropertyKeyValue] as? NSURL {
    return value.absoluteString
  }
  if let value = entry[kSecPropertyKeyValue as String] as? NSURL {
    return value.absoluteString
  }
  return nil
}

private func propertyValue(_ entry: NSDictionary) -> Any? {
  entry[kSecPropertyKeyValue] ?? entry[kSecPropertyKeyValue as String]
}

private func propertyDateValue(values: NSDictionary, oid: CFString) -> Date? {
  guard let outer = propertyDictionary(values: values, oid: oid) else {
    return nil
  }

  let rawValue = propertyValue(outer)

  if let date = rawValue as? Date {
    return date
  }
  if let string = rawValue as? String {
    return parseCertificateDate(string)
  }

  return nil
}

private func parseCertificateDate(_ string: String) -> Date? {
  let iso8601Formatter = ISO8601DateFormatter()
  if let date = iso8601Formatter.date(from: string) {
    return date
  }

  let formatters: [DateFormatter] = [
    makeDateFormatter("yyyy-MM-dd HH:mm:ss Z"),
    makeDateFormatter("yyyy-MM-dd HH:mm:ss"),
    makeDateFormatter("MMM d HH:mm:ss yyyy zzz"),
  ]

  for formatter in formatters {
    if let date = formatter.date(from: string) {
      return date
    }
  }

  return nil
}

private func makeDateFormatter(_ dateFormat: String) -> DateFormatter {
  let formatter = DateFormatter()
  formatter.locale = Locale(identifier: "en_US_POSIX")
  formatter.timeZone = TimeZone(secondsFromGMT: 0)
  formatter.dateFormat = dateFormat
  return formatter
}

private func statusMessage(_ status: OSStatus) -> String {
  SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
}
