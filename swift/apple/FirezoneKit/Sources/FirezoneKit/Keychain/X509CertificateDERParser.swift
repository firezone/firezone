//
//  X509CertificateDERParser.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
import Security

/// Extracts the certificate metadata we need before touching a private key.
///
/// Apple exposes `SecCertificateCopyValues` on macOS, but not in the iPhone SDK. To keep the
/// Network Extension behavior consistent across platforms, we parse the certificate DER directly.
/// This is intentionally not a general X.509 validator. It only extracts:
/// - Subject common name: used to select the tenant-configured device certificate.
/// - Extended Key Usage: must contain Client Authentication, otherwise the cert is not signable
///   for this protocol.
/// - Validity window: used as a local sanity check before signing.
///
/// Chain validation is server-side. The client proves possession of the private key by signing the
/// server nonce; the server then verifies that signature against the returned leaf certificate and
/// validates the leaf against the configured issuer/root CA.
func x509CertificateMetadata(for certificate: SecCertificate) -> X509CertificateMetadata {
  let parsedMetadata = X509CertificateDERParser(
    certificateDER: SecCertificateCopyData(certificate) as Data
  ).parse()

  var commonName: CFString?
  SecCertificateCopyCommonName(certificate, &commonName)

  // Prefer our DER parser so iOS and macOS use the same certificate interpretation. The Security
  // fallback is only for unusual encodings our intentionally small parser cannot read.
  let subjectCommonName =
    parsedMetadata.subjectCommonName
    ?? (commonName as String?
      ?? (SecCertificateCopySubjectSummary(certificate) as String? ?? "<unknown>"))

  return X509CertificateMetadata(
    subjectCommonName: subjectCommonName,
    extendedKeyUsageValues: parsedMetadata.extendedKeyUsageValues,
    notBefore: parsedMetadata.notBefore,
    notAfter: parsedMetadata.notAfter
  )
}

private enum X509ObjectIdentifier {
  // X.520 `commonName` attribute OID. In a certificate Subject this is the CN component, e.g.
  // `CN=dev.firezone.device-trust`. We use this only as a local selector requested by the server.
  static let commonName = "2.5.4.3"

  // RFC 5280 Extended Key Usage extension OID. The extension value is a sequence of purpose OIDs;
  // the policy layer requires the Client Authentication purpose before we will ask a key to sign.
  static let extendedKeyUsage = "2.5.29.37"
}

// Parser output is intentionally partial. Missing fields fail closed later: without a matching CN,
// client-auth EKU, and valid time window, the signer will not use the certificate.
private struct PartialX509CertificateMetadata {
  var subjectCommonName: String?
  var extendedKeyUsageValues: [String] = []
  var notBefore: Date?
  var notAfter: Date?

  static let empty = PartialX509CertificateMetadata()

  func mergingExtensions(_ extensions: PartialX509CertificateMetadata)
    -> PartialX509CertificateMetadata
  {
    // Subject and validity live in the TBSCertificate body; EKU lives under extensions. Keep the
    // merge explicit so extension parsing cannot overwrite the subject or validity fields.
    PartialX509CertificateMetadata(
      subjectCommonName: subjectCommonName,
      extendedKeyUsageValues: extensions.extendedKeyUsageValues,
      notBefore: notBefore,
      notAfter: notAfter
    )
  }
}

private struct X509CertificateDERParser {
  private let certificateDER: [UInt8]

  init(certificateDER: Data) {
    self.certificateDER = Array(certificateDER)
  }

  func parse() -> PartialX509CertificateMetadata {
    // Certificate bytes come from the Keychain but are still treated as untrusted input. Any parse
    // failure returns no metadata; without CN/EKU metadata the signer will not select the cert.
    guard
      let certificate = DERElement.first(in: certificateDER, tag: .sequence),
      let tbsCertificate = certificate.children.first(withTag: .sequence),
      let fields = TBSCertificateFields(tbsCertificate.children)
    else {
      return .empty
    }

    let validity = parseValidity(fields.validity)
    let metadata = PartialX509CertificateMetadata(
      subjectCommonName: parseSubjectCommonName(fields.subject),
      notBefore: validity.notBefore,
      notAfter: validity.notAfter
    )

    guard let extensions = fields.extensions else {
      return metadata
    }

    return metadata.mergingExtensions(parseExtensions(extensions))
  }

  private func parseSubjectCommonName(_ name: DERElement) -> String? {
    // X.509 Name = SEQUENCE OF RelativeDistinguishedName, where each RDN is a SET of attributes.
    // We only need CN=... for certificate selection; the server handles issuer-chain trust.
    return name.children
      .filter { $0.tag == .set }
      .flatMap(\.children)
      .compactMap(X509Attribute.init)
      .first { $0.objectIdentifier == X509ObjectIdentifier.commonName }
      .flatMap { stringValue(from: $0.value) }
  }

  private func parseValidity(_ validity: DERElement) -> (notBefore: Date?, notAfter: Date?) {
    let times = validity.children
    return (
      notBefore: times.first.flatMap(parseTime),
      notAfter: times.dropFirst().first.flatMap(parseTime)
    )
  }

  private func parseExtensions(_ extensions: DERElement) -> PartialX509CertificateMetadata {
    // TBSCertificate.extensions is [3] EXPLICIT Extensions, so the useful payload is the first
    // nested SEQUENCE. We ignore every extension except EKU because SANs/issuer hints are not part
    // of the local selection policy.
    guard let extensionSequence = extensions.children.first(withTag: .sequence) else {
      return .empty
    }

    var metadata = PartialX509CertificateMetadata.empty
    for extensionElement in extensionSequence.children {
      guard let certificateExtension = X509Extension(extensionElement) else {
        continue
      }

      switch certificateExtension.objectIdentifier {
      case X509ObjectIdentifier.extendedKeyUsage:
        metadata.extendedKeyUsageValues = parseExtendedKeyUsage(certificateExtension.value)
      default:
        continue
      }
    }

    return metadata
  }

  private func parseExtendedKeyUsage(_ extensionValueDER: [UInt8]) -> [String] {
    // extKeyUsage values are encoded as KeyPurposeId OIDs. Returning OID strings keeps policy
    // comparison deterministic across platforms and locales.
    guard let keyPurposeIDs = DERElement.first(in: extensionValueDER, tag: .sequence) else {
      return []
    }

    return keyPurposeIDs.children
      .filter { $0.tag == .objectIdentifier }
      .compactMap { objectIdentifierString(from: $0.value) }
  }

  private func stringValue(from element: DERElement) -> String? {
    // X.509 directory strings can use several ASN.1 string encodings. Accept the common textual
    // encodings for CN extraction; unknown encodings fail closed by returning nil.
    switch element.tag {
    case .utf8String, .printableString, .ia5String, .visibleString:
      return String(bytes: element.value, encoding: .utf8)
    case .bmpString:
      return String(data: Data(element.value), encoding: .utf16BigEndian)
    case .teletexString:
      return String(data: Data(element.value), encoding: .isoLatin1)
    default:
      return nil
    }
  }

  private func parseTime(_ element: DERElement) -> Date? {
    // Certificate validity times are ASCII UTCTime or GeneralizedTime in RFC 5280. Unsupported
    // tags are ignored so malformed validity does not crash the Network Extension.
    guard let string = String(bytes: element.value, encoding: .utf8) else {
      return nil
    }

    switch element.tag {
    case .utcTime:
      return parseUTCTime(string)
    case .generalizedTime:
      return parseGeneralizedTime(string)
    default:
      return nil
    }
  }
}

private struct TBSCertificateFields {
  let validity: DERElement
  let subject: DERElement
  let extensions: DERElement?

  init?(_ elements: [DERElement]) {
    // TBSCertificate starts with an optional [0] EXPLICIT version. After that, the fields we need
    // are fixed-position ASN.1 fields from RFC 5280:
    // serialNumber, signature, issuer, validity, subject, subjectPublicKeyInfo, ...
    let firstRequiredFieldIndex = elements.first?.tag == .contextSpecific0Constructed ? 1 : 0
    guard
      let validity = elements.element(at: firstRequiredFieldIndex + 3),
      let subject = elements.element(at: firstRequiredFieldIndex + 4)
    else {
      return nil
    }

    self.validity = validity
    self.subject = subject
    self.extensions =
      elements
      .dropFirst(firstRequiredFieldIndex + 6)
      .first(withTag: .contextSpecific3Constructed)
  }
}

private struct X509Attribute {
  let objectIdentifier: String
  let value: DERElement

  init?(_ element: DERElement) {
    // AttributeTypeAndValue = SEQUENCE { type OBJECT IDENTIFIER, value ANY }. For subject parsing,
    // we only care when `type` is commonName.
    guard
      element.tag == .sequence,
      let objectIdentifierElement = element.children.first,
      objectIdentifierElement.tag == .objectIdentifier,
      let objectIdentifier = objectIdentifierString(from: objectIdentifierElement.value),
      let value = element.children.dropFirst().first
    else {
      return nil
    }

    self.objectIdentifier = objectIdentifier
    self.value = value
  }
}

private struct X509Extension {
  let objectIdentifier: String
  let value: [UInt8]

  init?(_ element: DERElement) {
    // Extension = SEQUENCE { extnID OID, critical BOOLEAN OPTIONAL, extnValue OCTET STRING }.
    // We do not need the critical bit here because the client is only extracting metadata; the
    // server performs actual certificate-path validation.
    guard
      element.tag == .sequence,
      let objectIdentifierElement = element.children.first,
      objectIdentifierElement.tag == .objectIdentifier,
      let objectIdentifier = objectIdentifierString(from: objectIdentifierElement.value),
      let valueElement = element.children.dropFirst().first(withTag: .octetString)
    else {
      return nil
    }

    // Extension.extnValue is an OCTET STRING containing the DER for that extension's value.
    self.objectIdentifier = objectIdentifier
    self.value = valueElement.value
  }
}

private struct DERElement {
  let tag: UInt8
  let value: [UInt8]

  var children: [DERElement] {
    DERReader.readAll(from: value)
  }

  static func first(in bytes: [UInt8], tag: UInt8) -> DERElement? {
    DERReader.readAll(from: bytes).first(withTag: tag)
  }
}

private struct DERReader {
  private let bytes: [UInt8]
  private var offset = 0

  init(bytes: [UInt8]) {
    self.bytes = bytes
  }

  static func readAll(from bytes: [UInt8]) -> [DERElement] {
    var reader = DERReader(bytes: bytes)
    var elements: [DERElement] = []
    while let element = reader.readElement() {
      elements.append(element)
    }

    return elements
  }

  mutating func readElement() -> DERElement? {
    // This is a minimal definite-length DER reader. Returning nil on malformed length/value data
    // makes parsing fail closed instead of trying to recover from ambiguous certificate bytes.
    guard offset + 2 <= bytes.count else {
      return nil
    }

    let tag = bytes[offset]
    offset += 1

    guard let length = readLength(), offset + length <= bytes.count else {
      return nil
    }

    let value = Array(bytes[offset..<(offset + length)])
    offset += length
    return DERElement(tag: tag, value: value)
  }

  private mutating func readLength() -> Int? {
    guard offset < bytes.count else {
      return nil
    }

    let firstByte = bytes[offset]
    offset += 1
    if firstByte & 0x80 == 0 {
      return Int(firstByte)
    }

    let lengthByteCount = Int(firstByte & 0x7f)
    // DER forbids BER indefinite lengths (0x80). The 4-byte cap is enough for certificates and
    // prevents accidentally constructing huge Int values from hostile input.
    guard lengthByteCount > 0, lengthByteCount <= 4, offset + lengthByteCount <= bytes.count else {
      return nil
    }

    var length = 0
    for byte in bytes[offset..<(offset + lengthByteCount)] {
      length = (length << 8) | Int(byte)
    }
    offset += lengthByteCount
    return length
  }
}

extension UInt8 {
  // These constants are complete DER tag bytes, including class and constructed bits.
  fileprivate static let boolean: UInt8 = 0x01
  fileprivate static let objectIdentifier: UInt8 = 0x06
  fileprivate static let octetString: UInt8 = 0x04
  fileprivate static let utf8String: UInt8 = 0x0c
  fileprivate static let printableString: UInt8 = 0x13
  fileprivate static let teletexString: UInt8 = 0x14
  fileprivate static let ia5String: UInt8 = 0x16
  fileprivate static let utcTime: UInt8 = 0x17
  fileprivate static let generalizedTime: UInt8 = 0x18
  fileprivate static let visibleString: UInt8 = 0x1a
  fileprivate static let bmpString: UInt8 = 0x1e
  fileprivate static let sequence: UInt8 = 0x30
  fileprivate static let set: UInt8 = 0x31

  // Context-specific constructed tags used by TBSCertificate version and extensions.
  fileprivate static let contextSpecific0Constructed: UInt8 = 0xa0
  fileprivate static let contextSpecific3Constructed: UInt8 = 0xa3
}

extension Collection where Element == DERElement {
  fileprivate func first(withTag tag: UInt8) -> DERElement? {
    first { $0.tag == tag }
  }

  fileprivate func element(at offset: Int) -> DERElement? {
    guard offset >= 0 else {
      return nil
    }

    let index = self.index(startIndex, offsetBy: offset, limitedBy: endIndex)
    guard let index, index != endIndex else {
      return nil
    }

    return self[index]
  }
}

private func parseUTCTime(_ string: String) -> Date? {
  let timeString = string.hasSuffix("Z") ? String(string.dropLast()) : string
  guard
    timeString.count >= 12,
    let yearSuffix = intValue(timeString, range: 0..<2),
    let month = intValue(timeString, range: 2..<4),
    let day = intValue(timeString, range: 4..<6),
    let hour = intValue(timeString, range: 6..<8),
    let minute = intValue(timeString, range: 8..<10),
    let second = intValue(timeString, range: 10..<12)
  else {
    return nil
  }

  // RFC 5280 UTCTime uses 1950-2049 rollover. Anything outside that range is encoded as
  // GeneralizedTime instead.
  let year = yearSuffix >= 50 ? 1900 + yearSuffix : 2000 + yearSuffix
  return makeUTCDate(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
}

private func parseGeneralizedTime(_ string: String) -> Date? {
  let timeString = string.hasSuffix("Z") ? String(string.dropLast()) : string
  guard
    timeString.count >= 14,
    let year = intValue(timeString, range: 0..<4),
    let month = intValue(timeString, range: 4..<6),
    let day = intValue(timeString, range: 6..<8),
    let hour = intValue(timeString, range: 8..<10),
    let minute = intValue(timeString, range: 10..<12),
    let second = intValue(timeString, range: 12..<14)
  else {
    return nil
  }

  return makeUTCDate(year: year, month: month, day: day, hour: hour, minute: minute, second: second)
}

private func intValue(_ string: String, range: Range<Int>) -> Int? {
  guard string.count >= range.upperBound else {
    return nil
  }

  let start = string.index(string.startIndex, offsetBy: range.lowerBound)
  let end = string.index(string.startIndex, offsetBy: range.upperBound)
  return Int(string[start..<end])
}

private func makeUTCDate(
  year: Int,
  month: Int,
  day: Int,
  hour: Int,
  minute: Int,
  second: Int
) -> Date? {
  var components = DateComponents()
  components.calendar = Calendar(identifier: .gregorian)
  components.timeZone = TimeZone(secondsFromGMT: 0)
  components.year = year
  components.month = month
  components.day = day
  components.hour = hour
  components.minute = minute
  components.second = second
  return components.date
}

private func objectIdentifierString(from bytes: [UInt8]) -> String? {
  // Object identifiers encode the first two arcs in byte 0 and the remaining arcs as base-128
  // continuation groups. A dangling continuation bit means malformed DER, so return nil.
  guard let firstByte = bytes.first else {
    return nil
  }

  let firstValue = Int(firstByte)
  let firstComponent = min(firstValue / 40, 2)
  let secondComponent = firstValue - (firstComponent * 40)
  var components = [firstComponent, secondComponent]
  var currentComponent = 0

  for byte in bytes.dropFirst() {
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
