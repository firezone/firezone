import Foundation
import Security
import Testing

@testable import FirezoneKit

@Suite("X.509 Certificate Policy Tests")
struct X509CertificatePolicyTests {
  private let subjectCommonName = "dev.firezone.device-trust"
  private let now = Date(timeIntervalSince1970: 1_775_000_000)

  private func metadata(
    subjectCommonName: String = "dev.firezone.device-trust",
    extendedKeyUsageValues: [String] = ["TLS Web Client Authentication"],
    notBefore: Date? = nil,
    notAfter: Date? = nil
  ) -> X509CertificateMetadata {
    X509CertificateMetadata(
      subjectCommonName: subjectCommonName,
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
    let certificate = metadata(subjectCommonName: "other.firezone.device-trust")

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

  @Test("Security framework metadata parsing reads subject CN, validity, and client auth EKU")
  func parsesCertificateFixtureMetadata() throws {
    // Generated with:
    // mkdir -p /tmp/firezone-x509-fixture
    // printf '%s\n' '[v3_req]' 'basicConstraints=critical,CA:FALSE' \
    //   'keyUsage=critical,digitalSignature' 'extendedKeyUsage=clientAuth' \
    //   > /tmp/firezone-x509-fixture/client-auth.ext
    // openssl req -newkey rsa:2048 -nodes -keyout /tmp/firezone-x509-fixture/client-auth.key \
    //   -out /tmp/firezone-x509-fixture/client-auth.csr -subj "/CN=dev.firezone.device-trust"
    // openssl x509 -req -in /tmp/firezone-x509-fixture/client-auth.csr \
    //   -signkey /tmp/firezone-x509-fixture/client-auth.key \
    //   -out /tmp/firezone-x509-fixture/client-auth.pem -days 365 \
    //   -extfile /tmp/firezone-x509-fixture/client-auth.ext -extensions v3_req
    // openssl x509 -in /tmp/firezone-x509-fixture/client-auth.pem -outform DER \
    //   -out /tmp/firezone-x509-fixture/client-auth.der
    let derBase64 = """
      MIIDKjCCAhKgAwIBAgIUPEpPHeXIr6dK3fJaaaGi9taTjkIwDQYJKoZIhvcNAQELBQAwJDEiMCAGA1UEAwwZZGV2LmZpcmV6b25lLmRldmljZS10cnVzdDAeFw0yNjA0MjIxNTIwMjdaFw0yNzA0MjIxNTIwMjdaMCQxIjAgBgNVBAMMGWRldi5maXJlem9uZS5kZXZpY2UtdHJ1c3QwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQC0j7min0KgSWFEXAyDoUeegQVND+UxRfWQII7eW9t91+kRKNo1SGryJTVpNg8NEgC77g3azO631fLc4lWYla5P4roYPG7L5AcqoxFCAh+M16d3oslOGSGkH3bm5ZYHSzhqliPPUz91VbeCl3V0QsChANDSVpghLaKv8yw8dsjgiYkqGD/ZFKYcJAm88s3N7HimFKSfgA6+2E5v/8Iz6U4IYFP8pKrXJeV6UA/Dk7MS3VfOQEEW8n8kDqcjXc0sHVSYQ64KtROZVDOe1amEw+9hEKtbYQDjAutU3jbwZoi/0yemThbeSsCB6b+UIYdq6OEeD/yTdqVE0umvRycE6pFpAgMBAAGjVDBSMAwGA1UdEwEB/wQCMAAwDgYDVR0PAQH/BAQDAgeAMBMGA1UdJQQMMAoGCCsGAQUFBwMCMB0GA1UdDgQWBBT/P30ztmHh1qPYU0Lv7sCHyl9D1zANBgkqhkiG9w0BAQsFAAOCAQEAZUwLt/KtCnWbBSdHVu04M4DZ9uuRtZZoLhlcy40MRZVMideD3Ocfx4ft4JmNpUjzKiVD+SxU+J2pxQXAop7KUNDrBkFqWyfFV91JKmS3BIZaTTix2VwGgICmqeDY8JWEg3wipkzirnaTzgkLKQ7ho2oOnH206p+P8I8edlVYZwFsjBPHkYiILdTBuF+pnMQnGY92sI7a+q5m58q1EVld+V75sUyHaVFlag0tyxGvLVfUHT3I8bjgb01eGkcXTOEoJLuLTOCqPX4f2IBllkjUBufO8K9GkzuEWIw3Ob4yPe0tuLaxdZlQGMAecmquB7eN6Xc+ynY3OGNW+Q/O5vOGBw==
      """
    let normalizedDERBase64 = String(derBase64.filter { !$0.isWhitespace })
    let der = try #require(Data(base64Encoded: normalizedDERBase64))
    let certificate = try #require(SecCertificateCreateWithData(nil, der as CFData))

    let metadata = x509CertificateMetadata(for: certificate)

    #expect(metadata.subjectCommonName == subjectCommonName)
    #expect(metadata.notBefore != nil)
    #expect(metadata.notAfter != nil)
    #expect(X509CertificatePolicy.hasClientAuthenticationExtendedKeyUsage(metadata))
  }
}
