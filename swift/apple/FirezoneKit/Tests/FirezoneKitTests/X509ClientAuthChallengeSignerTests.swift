import Foundation
import Testing
@testable import FirezoneKit

@Suite("X.509 Client Auth Challenge Signer Tests")
struct X509ClientAuthChallengeSignerTests {
  private let subjectCommonName = "dev.firezone.scep"

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

  private func record(
    certificateDER: Data,
    metadata: X509CertificateMetadata,
    signingKey: (any X509ChallengeSigningKey)?
  ) -> X509IdentityRecord {
    X509IdentityRecord(
      certificateDER: certificateDER,
      metadata: metadata,
      copySigningKey: { signingKey }
    )
  }

  @Test("signChallenges returns every matching signable identity in newest-first order")
  func signChallengesReturnsEveryMatchingIdentity() throws {
    let nonce = nonceData()
    let oldKey = MockSigningKey(
      supportedAlgorithms: [.rsaSignatureMessagePKCS1v15SHA256],
      signatures: [.rsaSignatureMessagePKCS1v15SHA256: Data("old-signature".utf8)]
    )
    let newKey = MockSigningKey(
      supportedAlgorithms: [.rsaSignatureMessagePKCS1v15SHA256],
      signatures: [.rsaSignatureMessagePKCS1v15SHA256: Data("new-signature".utf8)]
    )

    let signer = X509ClientAuthChallengeSigner(
      loadIdentities: {
        [
          record(
            certificateDER: Data([0x01]),
            metadata: metadata(
              notBefore: Date().addingTimeInterval(-120),
              notAfter: Date().addingTimeInterval(120)
            ),
            signingKey: oldKey
          ),
          record(
            certificateDER: Data([0x02]),
            metadata: metadata(
              notBefore: Date().addingTimeInterval(-60),
              notAfter: Date().addingTimeInterval(120)
            ),
            signingKey: newKey
          ),
        ]
      }
    )

    let result = try signer.signChallenges(
      nonceBase64: nonce.base64EncodedString(),
      subjectCommonName: subjectCommonName
    )

    #expect(
      result.map(\.signedChallengeBase64) == [
        Data("new-signature".utf8).base64EncodedString(),
        Data("old-signature".utf8).base64EncodedString(),
      ]
    )
    #expect(
      result.map(\.leafCertificateDERBase64) == [
        Data([0x02]).base64EncodedString(),
        Data([0x01]).base64EncodedString(),
      ]
    )
    #expect(oldKey.signCalls == [SignCall(challenge: nonce, algorithm: .rsaSignatureMessagePKCS1v15SHA256)])
    #expect(newKey.signCalls == [SignCall(challenge: nonce, algorithm: .rsaSignatureMessagePKCS1v15SHA256)])
  }

  @Test("signChallenges filters by subject CN, client auth EKU, validity, signing key, and algorithm")
  func signChallengesFiltersInvalidIdentities() throws {
    let nonce = nonceData()
    let usableKey = MockSigningKey(
      supportedAlgorithms: [.ecdsaSignatureMessageX962SHA256],
      signatures: [.ecdsaSignatureMessageX962SHA256: Data("ecdsa-signature".utf8)]
    )
    let skippedKey = MockSigningKey(
      supportedAlgorithms: [.rsaSignatureMessagePKCS1v15SHA256],
      signatures: [.rsaSignatureMessagePKCS1v15SHA256: Data("wrong-signature".utf8)]
    )
    let unsupportedKey = MockSigningKey(supportedAlgorithms: [], signatures: [:])

    let signer = X509ClientAuthChallengeSigner(
      loadIdentities: {
        [
          record(
            certificateDER: Data([0x10]),
            metadata: metadata(),
            signingKey: usableKey
          ),
          record(
            certificateDER: Data([0x20]),
            metadata: metadata(subjectCommonName: "other.firezone.scep"),
            signingKey: skippedKey
          ),
          record(
            certificateDER: Data([0x30]),
            metadata: metadata(extendedKeyUsageValues: ["TLS Web Server Authentication"]),
            signingKey: skippedKey
          ),
          record(
            certificateDER: Data([0x40]),
            metadata: metadata(notAfter: Date().addingTimeInterval(-60)),
            signingKey: skippedKey
          ),
          record(
            certificateDER: Data([0x50]),
            metadata: metadata(),
            signingKey: nil
          ),
          record(
            certificateDER: Data([0x60]),
            metadata: metadata(),
            signingKey: unsupportedKey
          ),
        ]
      }
    )

    let result = try signer.signChallenges(nonce: nonce, subjectCommonName: subjectCommonName)

    #expect(result.count == 1)
    #expect(result[0].signedChallengeBase64 == Data("ecdsa-signature".utf8).base64EncodedString())
    #expect(result[0].leafCertificateDERBase64 == Data([0x10]).base64EncodedString())
    #expect(usableKey.signCalls == [SignCall(challenge: nonce, algorithm: .ecdsaSignatureMessageX962SHA256)])
    #expect(skippedKey.signCalls.isEmpty)
    #expect(unsupportedKey.signCalls.isEmpty)
  }

  @Test("signChallenges chooses the first supported algorithm in priority order")
  func signChallengesChoosesPreferredAlgorithm() throws {
    let nonce = nonceData()
    let key = MockSigningKey(
      supportedAlgorithms: [.rsaSignatureMessagePSSSHA256, .rsaSignatureMessagePKCS1v15SHA256],
      signatures: [.rsaSignatureMessagePKCS1v15SHA256: Data("pkcs1-signature".utf8)]
    )
    let signer = X509ClientAuthChallengeSigner(
      loadIdentities: {
        [
          record(
            certificateDER: Data([0xAA]),
            metadata: metadata(),
            signingKey: key
          )
        ]
      }
    )

    let result = try signer.signChallenges(nonce: nonce, subjectCommonName: subjectCommonName)

    #expect(result.map(\.signedChallengeBase64) == [Data("pkcs1-signature".utf8).base64EncodedString()])
    #expect(key.signCalls == [SignCall(challenge: nonce, algorithm: .rsaSignatureMessagePKCS1v15SHA256)])
  }

  @Test("signChallenges returns an empty payload when no identity matches")
  func signChallengesReturnsEmptyWhenNothingMatches() throws {
    let key = MockSigningKey(
      supportedAlgorithms: [.rsaSignatureMessagePKCS1v15SHA256],
      signatures: [.rsaSignatureMessagePKCS1v15SHA256: Data("signature".utf8)]
    )
    let signer = X509ClientAuthChallengeSigner(
      loadIdentities: {
        [
          record(
            certificateDER: Data([0x40]),
            metadata: metadata(subjectCommonName: "other.firezone.scep"),
            signingKey: key
          )
        ]
      }
    )

    let result = try signer.signChallenges(nonce: nonceData(), subjectCommonName: subjectCommonName)

    #expect(result.isEmpty)
    #expect(key.signCalls.isEmpty)
  }

  @Test("signChallenges only copies signing keys after certificate metadata matches")
  func signChallengesCopiesKeysOnlyForMetadataMatches() throws {
    let nonce = nonceData()
    var wrongSubjectCopies = 0
    var validSubjectCopies = 0
    let wrongSubjectKey = MockSigningKey(
      supportedAlgorithms: [.rsaSignatureMessagePKCS1v15SHA256],
      signatures: [.rsaSignatureMessagePKCS1v15SHA256: Data("wrong-signature".utf8)]
    )
    let validSubjectKey = MockSigningKey(
      supportedAlgorithms: [.rsaSignatureMessagePKCS1v15SHA256],
      signatures: [.rsaSignatureMessagePKCS1v15SHA256: Data("valid-signature".utf8)]
    )
    let signer = X509ClientAuthChallengeSigner(
      loadIdentities: {
        [
          X509IdentityRecord(
            certificateDER: Data([0x01]),
            metadata: metadata(subjectCommonName: "other.firezone.scep"),
            copySigningKey: {
              wrongSubjectCopies += 1
              return wrongSubjectKey
            }
          ),
          X509IdentityRecord(
            certificateDER: Data([0x02]),
            metadata: metadata(),
            copySigningKey: {
              validSubjectCopies += 1
              return validSubjectKey
            }
          ),
        ]
      }
    )

    let result = try signer.signChallenges(nonce: nonce, subjectCommonName: subjectCommonName)

    #expect(result.count == 1)
    #expect(wrongSubjectCopies == 0)
    #expect(validSubjectCopies == 1)
    #expect(wrongSubjectKey.signCalls.isEmpty)
    #expect(validSubjectKey.signCalls == [SignCall(challenge: nonce, algorithm: .rsaSignatureMessagePKCS1v15SHA256)])
  }

  @Test("signChallenges rejects invalid nonce base64 and nonce sizes")
  func signChallengesRejectsInvalidNonce() throws {
    let signer = X509ClientAuthChallengeSigner(loadIdentities: { [] })

    do {
      _ = try signer.signChallenges(nonceBase64: "%%% not base64 %%%", subjectCommonName: subjectCommonName)
      Issue.record("Expected signChallenges to reject invalid base64")
    } catch let error as X509ClientAuthChallengeSigner.Error {
      #expect(error == .invalidNonceBase64)
    }

    do {
      _ = try signer.signChallenges(nonce: Data([0x01]), subjectCommonName: subjectCommonName)
      Issue.record("Expected signChallenges to reject invalid nonce length")
    } catch let error as X509ClientAuthChallengeSigner.Error {
      #expect(error == .invalidNonceLength(expected: 32, actual: 1))
    }
  }

  @Test(
    "system keychain can sign a device trust nonce",
    .enabled(if: ProcessInfo.processInfo.environment["FIREZONE_TEST_SYSTEM_KEYCHAIN"] == "1")
  )
  func systemKeychainCanSignDeviceTrustNonce() throws {
    let subjectCommonName =
      ProcessInfo.processInfo.environment["FIREZONE_TEST_DEVICE_TRUST_CN"] ?? "dev.firezone.scep"

    let result = try X509ClientAuthChallengeSigner().signChallenges(
      nonce: nonceData(),
      subjectCommonName: subjectCommonName
    )

    #expect(!result.isEmpty)
    for signedChallenge in result {
      #expect(Data(base64Encoded: signedChallenge.signedChallengeBase64) != nil)
      #expect(Data(base64Encoded: signedChallenge.leafCertificateDERBase64) != nil)
    }
  }
}

private func nonceData() -> Data {
  Data((0..<32).map(UInt8.init))
}

private struct SignCall: Equatable {
  let challenge: Data
  let algorithm: X509SignatureAlgorithm
}

private final class MockSigningKey: X509ChallengeSigningKey {
  let supportedAlgorithms: Set<X509SignatureAlgorithm>
  let signatures: [X509SignatureAlgorithm: Data]
  private(set) var signCalls: [SignCall] = []

  init(supportedAlgorithms: Set<X509SignatureAlgorithm>, signatures: [X509SignatureAlgorithm: Data]) {
    self.supportedAlgorithms = supportedAlgorithms
    self.signatures = signatures
  }

  func isAlgorithmSupported(_ algorithm: X509SignatureAlgorithm) -> Bool {
    supportedAlgorithms.contains(algorithm)
  }

  func sign(challenge: Data, algorithm: X509SignatureAlgorithm) throws -> Data {
    signCalls.append(SignCall(challenge: challenge, algorithm: algorithm))

    guard let signature = signatures[algorithm] else {
      throw X509ClientAuthChallengeSigner.Error.signatureCreationFailed("Missing signature for \(algorithm)")
    }

    return signature
  }
}
