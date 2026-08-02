//
//  X509SubjectAlternativeNames.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

extension X509Identity {
  /// Security.framework does not expose a cross-platform SAN accessor, so read
  /// the subjectAltName extension directly from the certificate DER. Unknown
  /// GeneralName values remain available as DER/Base64 diagnostics.
  static func subjectAlternativeNames(certificateData: Data) -> String {
    do {
      guard let extensionValue = try subjectAlternativeNameExtension(in: certificateData) else {
        return "None"
      }

      let sequence = try singleElement(in: extensionValue, expectedTag: 0x30)
      let names = try elements(in: sequence.content)
      guard !names.isEmpty else { return "None" }

      return try names.map(formatSubjectAlternativeName).joined(separator: "\n")
    } catch {
      return "Could not parse (\(error.localizedDescription))"
    }
  }

  static func mdmDeviceId(certificateData: Data) -> String? {
    guard
      let extensionValue = try? subjectAlternativeNameExtension(in: certificateData),
      let sequence = try? singleElement(in: extensionValue, expectedTag: 0x30),
      let names = try? elements(in: sequence.content)
    else {
      return nil
    }

    let uris = names.compactMap { element -> String? in
      guard element.tag & 0xC0 == 0x80, Int(element.tag & 0x1F) == 6 else { return nil }
      return try? stringValue(element.content, context: "URI")
    }.filter { !$0.hasPrefix("tag:microsoft.com,2022-09-14:sid:") }

    var sawTypedIdentifier = false
    var typedMdmDeviceId: String?
    let knownTypes: Set<String> = [
      "serial", "apple-serial", "udid", "apple-udid", "smbios-uuid",
      "intune-id", "entra-id", "ws1-uuid", "jamf-id", "kandji-id",
    ]
    let mdmTypes: Set<String> = [
      "intune-id", "entra-id", "ws1-uuid", "jamf-id", "kandji-id",
    ]

    for uri in uris {
      guard let separator = uri.range(of: "://") else { continue }
      guard String(uri[..<separator.lowerBound]).caseInsensitiveCompare("firezone") == .orderedSame
      else { continue }
      let remainder = uri[separator.upperBound...]
      guard let slash = remainder.firstIndex(of: "/") else { continue }
      let idType = remainder[..<slash].lowercased()
      let value = String(remainder[remainder.index(after: slash)...])
      guard knownTypes.contains(idType), validIdentifier(value) else { continue }

      sawTypedIdentifier = true
      if mdmTypes.contains(idType), typedMdmDeviceId == nil {
        typedMdmDeviceId = normalizeMdmDeviceId(value)
      }
    }

    if sawTypedIdentifier {
      return typedMdmDeviceId
    }

    return uris.lazy.compactMap { value -> String? in
      let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
      guard trimmed.count == 36, UUID(uuidString: trimmed) != nil else { return nil }
      return normalizeMdmDeviceId(trimmed)
    }.first
  }

  private static func validIdentifier(_ value: String) -> Bool {
    let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
    return !trimmed.isEmpty && trimmed.utf8.count <= 255
      && trimmed.utf8.allSatisfy { (0x20...0x7E).contains($0) }
  }

  private static func normalizeMdmDeviceId(_ value: String) -> String? {
    let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let sentinels: Set<String> = [
      "0",
      "00000000-0000-0000-0000-000000000000",
      "ffffffff-ffff-ffff-ffff-ffffffffffff",
      "03000200-0400-0500-0006-000700080009",
      "idnotpresentbutsettable",
    ]
    guard validIdentifier(normalized), !sentinels.contains(normalized) else { return nil }
    return normalized
  }

  private static let subjectAlternativeNameOID = "2.5.29.17"

  private struct DERElement {
    let tag: UInt8
    let content: Data
    let encoded: Data
  }

  private enum DERError: LocalizedError {
    case malformed(String)

    var errorDescription: String? {
      switch self {
      case .malformed(let message):
        return message
      }
    }
  }

  private static func subjectAlternativeNameExtension(in certificateData: Data) throws -> Data? {
    let certificate = try singleElement(in: certificateData, expectedTag: 0x30)
    let certificateFields = try elements(in: certificate.content)
    guard let tbsCertificate = certificateFields.first, tbsCertificate.tag == 0x30 else {
      throw DERError.malformed("certificate does not contain a TBSCertificate sequence")
    }

    let tbsFields = try elements(in: tbsCertificate.content)
    guard let extensionsWrapper = tbsFields.first(where: { $0.tag == 0xA3 }) else {
      return nil
    }

    let extensions = try singleElement(in: extensionsWrapper.content, expectedTag: 0x30)
    for encodedExtension in try elements(in: extensions.content) {
      guard encodedExtension.tag == 0x30 else { continue }
      let fields = try elements(in: encodedExtension.content)
      guard
        let oidField = fields.first,
        oidField.tag == 0x06,
        try decodeOID(oidField.content) == subjectAlternativeNameOID
      else {
        continue
      }

      var valueIndex = 1
      if fields.indices.contains(valueIndex), fields[valueIndex].tag == 0x01 {
        valueIndex += 1
      }
      guard fields.indices.contains(valueIndex), fields[valueIndex].tag == 0x04 else {
        throw DERError.malformed("subjectAltName extension has no OCTET STRING value")
      }
      return fields[valueIndex].content
    }

    return nil
  }

  private static func formatSubjectAlternativeName(_ element: DERElement) throws -> String {
    guard element.tag & 0xC0 == 0x80, element.tag & 0x1F != 0x1F else {
      throw DERError.malformed(
        String(format: "invalid GeneralName tag 0x%02X", element.tag))
    }

    let type = Int(element.tag & 0x1F)
    let label = generalNameLabel(type)
    let value: String

    switch type {
    case 1, 2, 6:
      value = try stringValue(element.content, context: label)
    case 4:
      value = try distinguishedName(element.content)
    case 7:
      value = try ipAddress(element.content)
    case 8:
      value = try decodeOID(element.content)
    default:
      value = "DER/Base64 \(element.encoded.base64EncodedString())"
    }

    return "\(label): \(value)"
  }

  private static func generalNameLabel(_ type: Int) -> String {
    switch type {
    case 0: "Other name"
    case 1: "Email"
    case 2: "DNS"
    case 3: "X.400 address"
    case 4: "Directory name"
    case 5: "EDI party name"
    case 6: "URI"
    case 7: "IP address"
    case 8: "Registered ID"
    default: "Type \(type)"
    }
  }

  private static func stringValue(_ data: Data, context: String) throws -> String {
    guard let value = String(data: data, encoding: .ascii) else {
      throw DERError.malformed("\(context) is not valid IA5String data")
    }
    return value
  }

  private static func ipAddress(_ data: Data) throws -> String {
    let bytes = [UInt8](data)
    switch bytes.count {
    case 4:
      return bytes.map(String.init).joined(separator: ".")
    case 16:
      return stride(from: 0, to: bytes.count, by: 2).map { index in
        String(format: "%02x%02x", bytes[index], bytes[index + 1])
      }.joined(separator: ":")
    default:
      throw DERError.malformed("IP address has \(bytes.count) bytes instead of 4 or 16")
    }
  }

  private static func distinguishedName(_ data: Data) throws -> String {
    let name = try singleElement(in: data, expectedTag: 0x30)
    let relativeNames = try elements(in: name.content)
    var renderedRelativeNames: [String] = []

    for relativeName in relativeNames {
      guard relativeName.tag == 0x31 else {
        throw DERError.malformed("directoryName contains a non-SET relative name")
      }

      let attributes = try elements(in: relativeName.content)
      let renderedAttributes = try attributes.map { attribute -> String in
        guard attribute.tag == 0x30 else {
          throw DERError.malformed("directoryName contains an invalid attribute")
        }
        let fields = try elements(in: attribute.content)
        guard fields.count == 2, fields[0].tag == 0x06 else {
          throw DERError.malformed("directoryName attribute is missing its OID or value")
        }

        let oid = try decodeOID(fields[0].content)
        return "\(distinguishedNameLabel(oid))=\(try directoryString(fields[1]))"
      }
      renderedRelativeNames.append(renderedAttributes.joined(separator: "+"))
    }

    return renderedRelativeNames.reversed().joined(separator: ",")
  }

  private static func distinguishedNameLabel(_ oid: String) -> String {
    switch oid {
    case "2.5.4.3": "CN"
    case "2.5.4.5": "SERIALNUMBER"
    case "2.5.4.6": "C"
    case "2.5.4.7": "L"
    case "2.5.4.8": "ST"
    case "2.5.4.10": "O"
    case "2.5.4.11": "OU"
    case "0.9.2342.19200300.100.1.1": "UID"
    case "0.9.2342.19200300.100.1.25": "DC"
    case "1.2.840.113549.1.9.1": "EMAILADDRESS"
    default: oid
    }
  }

  private static func directoryString(_ element: DERElement) throws -> String {
    let encoding: String.Encoding?
    switch element.tag {
    case 0x0C:
      encoding = .utf8
    case 0x12, 0x13, 0x14, 0x16, 0x1A:
      encoding = .isoLatin1
    case 0x1C:
      encoding = .utf32BigEndian
    case 0x1E:
      encoding = .utf16BigEndian
    default:
      encoding = nil
    }

    guard let encoding, let value = String(data: element.content, encoding: encoding) else {
      return "DER/Base64 \(element.encoded.base64EncodedString())"
    }
    return value
  }

  private static func decodeOID(_ data: Data) throws -> String {
    guard !data.isEmpty else { throw DERError.malformed("OID is empty") }

    var components: [UInt64] = []
    var component: UInt64 = 0
    var hasContinuation = false

    for byte in data {
      guard component <= (UInt64.max >> 7) else {
        throw DERError.malformed("OID component overflowed")
      }
      component = (component << 7) | UInt64(byte & 0x7F)
      hasContinuation = byte & 0x80 != 0
      if !hasContinuation {
        components.append(component)
        component = 0
      }
    }

    guard !hasContinuation, let firstCombined = components.first else {
      throw DERError.malformed("OID has a truncated component")
    }

    let first = min(firstCombined / 40, 2)
    let second = firstCombined - (first * 40)
    return ([first, second] + components.dropFirst()).map(String.init).joined(separator: ".")
  }

  private static func singleElement(in data: Data, expectedTag: UInt8) throws -> DERElement {
    let parsed = try elements(in: data)
    guard parsed.count == 1, parsed[0].tag == expectedTag else {
      throw DERError.malformed(
        String(format: "expected one DER element with tag 0x%02X", expectedTag))
    }
    return parsed[0]
  }

  private static func elements(in data: Data) throws -> [DERElement] {
    let bytes = [UInt8](data)
    var offset = 0
    var result: [DERElement] = []

    while offset < bytes.count {
      let elementStart = offset
      guard bytes.indices.contains(offset) else {
        throw DERError.malformed("DER element is missing its tag")
      }
      let tag = bytes[offset]
      offset += 1

      guard bytes.indices.contains(offset) else {
        throw DERError.malformed("DER element is missing its length")
      }
      let firstLengthByte = bytes[offset]
      offset += 1

      let contentLength: Int
      if firstLengthByte & 0x80 == 0 {
        contentLength = Int(firstLengthByte)
      } else {
        let lengthByteCount = Int(firstLengthByte & 0x7F)
        guard lengthByteCount > 0 else {
          throw DERError.malformed("indefinite DER lengths are unsupported")
        }
        guard lengthByteCount <= MemoryLayout<Int>.size, offset + lengthByteCount <= bytes.count
        else {
          throw DERError.malformed("DER length is truncated or too large")
        }

        var decodedLength = 0
        for lengthByte in bytes[offset..<(offset + lengthByteCount)] {
          guard decodedLength <= (Int.max >> 8) else {
            throw DERError.malformed("DER length overflowed")
          }
          decodedLength = (decodedLength << 8) | Int(lengthByte)
        }
        offset += lengthByteCount
        contentLength = decodedLength
      }

      guard contentLength <= bytes.count - offset else {
        throw DERError.malformed("DER content extends past the available data")
      }
      let contentEnd = offset + contentLength
      result.append(
        DERElement(
          tag: tag,
          content: Data(bytes[offset..<contentEnd]),
          encoded: Data(bytes[elementStart..<contentEnd])
        )
      )
      offset = contentEnd
    }

    return result
  }
}
