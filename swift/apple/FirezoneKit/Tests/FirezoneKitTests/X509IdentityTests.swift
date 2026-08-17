//
//  X509IdentityTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
import Testing

@testable import FirezoneKit

@Suite("X.509 Identity Tests")
struct X509IdentityTests {
  @Test("Missing VPN identity is reported as an expected empty configuration")
  func missingIdentityDetails() throws {
    let details = try X509Identity.details(persistentReference: nil)

    #expect(details.summary.contains("No X.509 identity"))
    #expect(details.sections.count == 1)
    #expect(details.sections[0].fields[0].value == "Not configured")
    #expect(
      details.textDescription == """
        No X.509 identity is configured for this VPN configuration.

        [VPN Configuration]
        Identity Reference:
          Not configured

        """)
  }

  @Test("Missing VPN identity produces no mutual-TLS identity")
  func missingClientTlsIdentity() throws {
    #expect(try X509Identity.clientTlsIdentity(persistentReference: nil) == nil)
  }

  @Test("Subject alternative name attributes are parsed from certificate DER")
  func subjectAlternativeNamesAreParsed() {
    let directoryName = der(
      0x30,
      der(
        0x31,
        der(
          0x30,
          der(0x06, Data([0x55, 0x04, 0x03]))
            + der(0x0C, Data("directory.example.com".utf8))
        )
      )
    )
    let generalNames: [Data] = [
      der(0xA0, der(0x06, Data([0x2A, 0x03, 0x04]))),
      der(0x81, Data("admin@example.com".utf8)),
      der(0x82, Data("device.example.com".utf8)),
      der(0xA3, der(0x30, Data())),
      der(0xA4, directoryName),
      der(0xA5, der(0x30, Data())),
      der(0x86, Data("firezone://intune/device-id".utf8)),
      der(0x87, Data([192, 0, 2, 1])),
      der(0x87, Data([0x20, 0x01, 0x0D, 0xB8] + Array(repeating: 0, count: 12))),
      der(0x88, Data([0x2A, 0x03, 0x04])),
    ]
    let names = der(
      0x30,
      generalNames.reduce(into: Data()) { result, name in result.append(name) }
    )
    let sanExtension = der(
      0x30,
      der(0x06, Data([0x55, 0x1D, 0x11]))
        + der(0x01, Data([0xFF]))
        + der(0x04, names)
    )
    let certificate = der(
      0x30,
      der(
        0x30,
        der(0x02, Data([0x01]))
          + der(0xA3, der(0x30, sanExtension))
      )
    )

    let rendered = X509Identity.subjectAlternativeNames(certificateData: certificate)
    let fields = X509Identity.subjectAlternativeNameFields(certificateData: certificate)

    #expect(rendered.contains("Other name: DER/Base64"))
    #expect(rendered.contains("Email: admin@example.com"))
    #expect(rendered.contains("DNS: device.example.com"))
    #expect(rendered.contains("X.400 address: DER/Base64"))
    #expect(rendered.contains("Directory name: CN=directory.example.com"))
    #expect(rendered.contains("EDI party name: DER/Base64"))
    #expect(rendered.contains("URI: firezone://intune/device-id"))
    #expect(rendered.contains("IP address: 192.0.2.1"))
    #expect(rendered.contains("IP address: 2001:0db8:0000:0000:0000:0000:0000:0000"))
    #expect(rendered.contains("Registered ID: 1.2.3.4"))
    #expect(fields.count == 10)
    #expect(fields.contains { $0.label == "Email" && $0.value == "admin@example.com" })
    #expect(fields.contains { $0.label == "URI" && $0.value == "firezone://intune/device-id" })
  }

  @Test("Certificate without subject alternative names reports none")
  func missingSubjectAlternativeNames() {
    let certificate = der(0x30, der(0x30, der(0x02, Data([0x01]))))

    #expect(X509Identity.subjectAlternativeNames(certificateData: certificate) == "None")
  }

  @Test("MDM device identifier is parsed from a typed URI SAN")
  func mdmDeviceIdIsParsed() {
    let names = der(
      0x30,
      der(0x86, Data("firezone://serial/C02XK1ZGJGH5".utf8))
        + der(
          0x86,
          Data("firezone://intune-id/5F2E7B7A-9D54-4BD2-9D4F-8F6C2A01F9D3".utf8)
        )
    )
    let sanExtension = der(
      0x30,
      der(0x06, Data([0x55, 0x1D, 0x11])) + der(0x04, names)
    )
    let certificate = der(
      0x30,
      der(0x30, der(0x02, Data([0x01])) + der(0xA3, der(0x30, sanExtension)))
    )

    #expect(
      X509Identity.mdmDeviceId(certificateData: certificate)
        == "5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3"
    )
  }

  @Test("MDM device identifier is parsed from Intune's comma-joined URI SAN")
  func commaJoinedMdmDeviceIdIsParsed() {
    let joinedUris =
      "tag:microsoft.com,2022-09-14:sid:S-1-12-1-1, "
      + "firezone://serial/C02XK1ZGJGH5, "
      + "firezone://intune-id/5F2E7B7A-9D54-4BD2-9D4F-8F6C2A01F9D3"
    let names = der(0x30, der(0x86, Data(joinedUris.utf8)))
    let sanExtension = der(
      0x30,
      der(0x06, Data([0x55, 0x1D, 0x11])) + der(0x04, names)
    )
    let certificate = der(
      0x30,
      der(0x30, der(0x02, Data([0x01])) + der(0xA3, der(0x30, sanExtension)))
    )

    #expect(
      X509Identity.mdmDeviceId(certificateData: certificate)
        == "5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3"
    )
  }

  @Test("Certificate user identity is parsed from Intune's comma-joined URI SAN")
  func commaJoinedUserIdentityIsParsed() {
    let joinedUris =
      "tag:microsoft.com,2022-09-14:sid:S-1-12-1-1, "
      + "firezone://email/Alice%40Example.COM, "
      + "firezone://account-id/5F2E7B7A-9D54-4BD2-9D4F-8F6C2A01F9D3, "
      + "firezone://intune-id/ADBCB238-5C99-47D6-957D-F14A1B3C7E41, "
      + "firezone://serial/C02XK1ZGJGH5"
    let certificate = certificateWithUriSAN(joinedUris)

    #expect(
      X509Identity.userIdentity(certificateData: certificate)
        == X509UserIdentity(
          email: "alice@example.com",
          accountId: "5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3"
        )
    )

    let sanFields = X509Identity.subjectAlternativeNameFields(certificateData: certificate)
    #expect(sanFields.map(\.label) == ["URI", "URI", "URI", "URI", "URI"])
    #expect(
      sanFields.map(\.value) == [
        "tag:microsoft.com,2022-09-14:sid:S-1-12-1-1",
        "firezone://email/Alice%40Example.COM",
        "firezone://account-id/5F2E7B7A-9D54-4BD2-9D4F-8F6C2A01F9D3",
        "firezone://intune-id/ADBCB238-5C99-47D6-957D-F14A1B3C7E41",
        "firezone://serial/C02XK1ZGJGH5",
      ]
    )
    #expect(X509Identity.actorEmail(certificateData: certificate) == "alice@example.com")
    #expect(
      X509Identity.accountId(certificateData: certificate)
        == "5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3"
    )
    #expect(
      X509Identity.mdmDeviceId(certificateData: certificate)
        == "adbcb238-5c99-47d6-957d-f14a1b3c7e41"
    )
    #expect(X509Identity.deviceSerial(certificateData: certificate) == "C02XK1ZGJGH5")
    let attributeFields = X509Identity.firezoneAttributeFields(certificateData: certificate)
    #expect(
      attributeFields.map(\.label) == [
        "Actor Email", "Account ID", "MDM Device ID", "Device Serial",
      ]
    )
    #expect(
      attributeFields.map(\.value) == [
        "alice@example.com",
        "5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3",
        "adbcb238-5c99-47d6-957d-f14a1b3c7e41",
        "C02XK1ZGJGH5",
      ]
    )
  }

  @Test("Certificate user identity requires unambiguous email and account ID attributes")
  func userIdentityRequiresCompleteUnambiguousAttributes() {
    let missingAccount = certificateWithUriSAN("firezone://email/alice@example.com")
    let conflictingEmail = certificateWithUriSAN(
      "firezone://email/alice@example.com,firezone://email/bob@example.com,"
        + "firezone://account-id/5f2e7b7a-9d54-4bd2-9d4f-8f6c2a01f9d3"
    )
    let malformedAccount = certificateWithUriSAN(
      "firezone://email/alice@example.com,firezone://account-id/not-a-uuid"
    )

    #expect(X509Identity.userIdentity(certificateData: missingAccount) == nil)
    #expect(X509Identity.userIdentity(certificateData: conflictingEmail) == nil)
    #expect(X509Identity.userIdentity(certificateData: malformedAccount) == nil)
    #expect(
      X509Identity.firezoneAttributeFields(certificateData: missingAccount).map(\.label)
        == ["Actor Email"]
    )
  }

  private func certificateWithUriSAN(_ uri: String) -> Data {
    let names = der(0x30, der(0x86, Data(uri.utf8)))
    let sanExtension = der(
      0x30,
      der(0x06, Data([0x55, 0x1D, 0x11])) + der(0x04, names)
    )
    return der(
      0x30,
      der(0x30, der(0x02, Data([0x01])) + der(0xA3, der(0x30, sanExtension)))
    )
  }

  private func der(_ tag: UInt8, _ content: Data) -> Data {
    var encoded = Data([tag])
    if content.count < 0x80 {
      encoded.append(UInt8(content.count))
    } else {
      let lengthBytes = withUnsafeBytes(of: UInt32(content.count).bigEndian) { bytes in
        Array(bytes.drop(while: { $0 == 0 }))
      }
      encoded.append(0x80 | UInt8(lengthBytes.count))
      encoded.append(contentsOf: lengthBytes)
    }
    encoded.append(content)
    return encoded
  }
}
