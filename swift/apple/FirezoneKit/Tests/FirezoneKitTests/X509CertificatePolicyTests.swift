import Foundation
import Security
import Testing
@testable import FirezoneKit

@Suite("X.509 Certificate Policy Tests")
struct X509CertificatePolicyTests {
  private let subjectCommonName = "dev.firezone.scep"
  private let now = Date(timeIntervalSince1970: 1_775_000_000)

  private func metadata(
    subjectCommonName: String = "dev.firezone.scep",
    extendedKeyUsageValues: [String] = ["TLS Web Client Authentication"],
    notBefore: Date? = nil,
    notAfter: Date? = nil
  ) -> X509CertificateMetadata {
    X509CertificateMetadata(
      subjectCommonName: subjectCommonName,
      sanValues: [],
      extendedKeyUsageValues: extendedKeyUsageValues,
      notBefore: notBefore,
      notAfter: notAfter
    )
  }

  @Test("matching client auth identity requires subject CN, client auth EKU, and validity window")
  func matchesClientAuthIdentity() {
    let certificate = metadata(
      notBefore: now.addingTimeInterval(-60),
      notAfter: now.addingTimeInterval(60)
    )

    #expect(
      X509CertificatePolicy.matchesClientAuthIdentity(
        certificate,
        subjectCommonName: subjectCommonName,
        now: now
      )
    )
  }

  @Test("matching client auth identity rejects mismatched subject CN")
  func rejectsMismatchedSubjectCommonName() {
    let certificate = metadata(subjectCommonName: "other.firezone.scep")

    #expect(
      !X509CertificatePolicy.matchesClientAuthIdentity(
        certificate,
        subjectCommonName: subjectCommonName,
        now: now
      )
    )
  }

  @Test("matching client auth identity rejects certificates without client auth EKU")
  func rejectsMissingClientAuthenticationEKU() {
    let certificate = metadata(extendedKeyUsageValues: ["TLS Web Server Authentication"])

    #expect(
      !X509CertificatePolicy.matchesClientAuthIdentity(
        certificate,
        subjectCommonName: subjectCommonName,
        now: now
      )
    )
  }

  @Test("client auth EKU accepts OID and Security framework labels")
  func acceptsClientAuthenticationEKURepresentations() {
    #expect(
      X509CertificatePolicy.hasClientAuthenticationExtendedKeyUsage(
        metadata(extendedKeyUsageValues: ["1.3.6.1.5.5.7.3.2"])
      )
    )
    #expect(
      X509CertificatePolicy.hasClientAuthenticationExtendedKeyUsage(
        metadata(extendedKeyUsageValues: ["TLS Web Client Authentication"])
      )
    )
  }

  @Test("matching client auth identity rejects certificates outside their validity window")
  func rejectsInvalidValidityWindow() {
    let notYetValid = metadata(notBefore: now.addingTimeInterval(60))
    let expired = metadata(notAfter: now.addingTimeInterval(-60))

    #expect(
      !X509CertificatePolicy.matchesClientAuthIdentity(
        notYetValid,
        subjectCommonName: subjectCommonName,
        now: now
      )
    )
    #expect(
      !X509CertificatePolicy.matchesClientAuthIdentity(
        expired,
        subjectCommonName: subjectCommonName,
        now: now
      )
    )
  }

  @Test("recency ordering prefers newer notBefore dates")
  func prefersNewerNotBeforeDate() {
    let older = metadata(
      notBefore: now.addingTimeInterval(-120),
      notAfter: now.addingTimeInterval(60)
    )
    let newer = metadata(
      notBefore: now.addingTimeInterval(-60),
      notAfter: now.addingTimeInterval(60)
    )

    #expect(X509CertificatePolicy.isOlder(older, than: newer))
    #expect(!X509CertificatePolicy.isOlder(newer, than: older))
  }

  @Test("recency ordering prefers newer notAfter dates when notBefore matches")
  func prefersNewerNotAfterDate() {
    let older = metadata(
      notBefore: now.addingTimeInterval(-60),
      notAfter: now.addingTimeInterval(60)
    )
    let newer = metadata(
      notBefore: now.addingTimeInterval(-60),
      notAfter: now.addingTimeInterval(120)
    )

    #expect(X509CertificatePolicy.isOlder(older, than: newer))
    #expect(!X509CertificatePolicy.isOlder(newer, than: older))
  }

  @Test("Security framework metadata parsing reads subject CN, SAN values, and client auth EKU")
  func parsesCertificateFixtureMetadata() throws {
    // Generated with:
    // mkdir -p /tmp/firezone-x509-fixture
    // printf '%s\n' '[v3_req]' 'basicConstraints=critical,CA:FALSE' \
    //   'keyUsage=critical,digitalSignature' 'extendedKeyUsage=clientAuth' \
    //   'subjectAltName=URI:deviceid:29540407-7527-4e2a-8614-e8f6ba1c6745,URI:serial:MJLFG7WJ39' \
    //   > /tmp/firezone-x509-fixture/client-auth.ext
    // openssl req -newkey rsa:2048 -nodes -keyout /tmp/firezone-x509-fixture/client-auth.key \
    //   -out /tmp/firezone-x509-fixture/client-auth.csr -subj "/CN=dev.firezone.scep"
    // openssl x509 -req -in /tmp/firezone-x509-fixture/client-auth.csr \
    //   -signkey /tmp/firezone-x509-fixture/client-auth.key \
    //   -out /tmp/firezone-x509-fixture/client-auth.pem -days 365 \
    //   -extfile /tmp/firezone-x509-fixture/client-auth.ext -extensions v3_req
    // openssl x509 -in /tmp/firezone-x509-fixture/client-auth.pem -outform DER \
    //   -out /tmp/firezone-x509-fixture/client-auth.der
    let derBase64 = """
      MIIDaTCCAlGgAwIBAgIUcNJBAScuQJMmmtW3f6mkGBhHXSEwDQYJKoZIhvcNAQELBQAwHDEaMBgGA1UEAwwRZGV2LmZpcmV6b25lLnNjZXAwHhcNMjYwNDIyMDQwODM4WhcNMjcwNDIyMDQwODM4WjAcMRowGAYDVQQDDBFkZXYuZmlyZXpvbmUuc2NlcDCCASIwDQYJKoZIhvcNAQEBBQADggEPADCCAQoCggEBALSw5cuviRyk4GHmF7+x4rUKaq9glQCOCOWivcP62Kb9AbnqOUXxyNgqJtRy8D44u4OzrNv8QML/d208I3A7BL66XpDYhpKkKiWUscrvzfMdOnVz7U0aswHGUUWA4Mx4ija918SQNcmDL31s2e+65CCKoLI/7/BJqUoPSIY5jei2pOpcUpRKXyV8foycidyEoOkbrhfF1WGKx+afb07vCA8LQeRRym9UdM6wALhdNKBbNpMiHrxepJ7CfIF6gnZzVAg2+HIhQ8Z2ajrSIKSEu25NZiwaQp232SPsqj36swGBhHZjIoLmV3g4UyS1pjV8K7aoTNnuFMkNNn0G4H0kaSsCAwEAAaOBojCBnzAMBgNVHRMBAf8EAjAAMA4GA1UdDwEB/wQEAwIHgDATBgNVHSUEDDAKBggrBgEFBQcDAjBLBgNVHREERDBChi1kZXZpY2VpZDoyOTU0MDQwNy03NTI3LTRlMmEtODYxNC1lOGY2YmExYzY3NDWGEXNlcmlhbDpNSkxGRzdXSjM5MB0GA1UdDgQWBBT0K2+4BOHXpO2oalmLomQmzS1nbTANBgkqhkiG9w0BAQsFAAOCAQEAHFvAXLpP/KHR4Yh2TeuIHmgFdUikBCyxGsDRDhFXY13CjAudac71d9yQG/q/JSoqvt+vXy6Gs/AfRrM4QOLlDeRr6OJAHoDjNJZhTPeYS+N8v9MGL2wDGNswNoSR/TtvdJOjjBRuX18qiwJRM7Q63AefLHtBGZ7ptaUnOglATKyT+0i9+dX4tHrQQ+3AiIA3ykWGcQ8EUWR8vcbtmBxFq+w1CACvu7E9QEl69kopFtbqr03aJFOCziHh913tc120CO73wMApt54JiB69f+Yp3QPi4PbY6Z/EG5VtVuRKW4wwZfeNm9AcLBRaW62tZbyhQbNq/03o6EKrdYMx3fhQTw==
      """
    let normalizedDERBase64 = String(derBase64.filter { !$0.isWhitespace })
    let der = try #require(Data(base64Encoded: normalizedDERBase64))
    let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData))

    let metadata = x509CertificateMetadata(for: certificate)

    #expect(metadata.subjectCommonName == subjectCommonName)
    #expect(metadata.sanValues.contains(where: { $0.contains("deviceid:29540407-7527-4e2a-8614-e8f6ba1c6745") }))
    #expect(metadata.sanValues.contains(where: { $0.contains("serial:MJLFG7WJ39") }))
    #expect(X509CertificatePolicy.hasClientAuthenticationExtendedKeyUsage(metadata))
  }
}
