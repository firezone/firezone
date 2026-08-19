//
//  X509IdentityTests.swift
//  © 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
import Security
import Testing

@testable import FirezoneKit

@Suite("X509 Identity Tests")
struct X509IdentityTests {
  @Test("An RSA key advertises PSS ahead of PKCS#1")
  func rsaAdvertisesPssBeforePkcs1() throws {
    let key = try makeKey(type: kSecAttrKeyTypeRSA, sizeInBits: 2048)

    let schemes = try X509Identity.signatureSchemes(for: key)

    #expect(
      schemes == [
        .rsaPssSha512, .rsaPssSha384, .rsaPssSha256,
        .rsaPkcs1Sha512, .rsaPkcs1Sha384, .rsaPkcs1Sha256,
      ])
  }

  @Test("An elliptic-curve key advertises only the scheme for its curve")
  func ellipticCurveAdvertisesOneScheme() throws {
    let expected: [(sizeInBits: Int, scheme: X509SignatureScheme)] = [
      (256, .ecdsaNistp256Sha256),
      (384, .ecdsaNistp384Sha384),
      (521, .ecdsaNistp521Sha512),
    ]

    for (sizeInBits, scheme) in expected {
      let key = try makeKey(type: kSecAttrKeyTypeECSECPrimeRandom, sizeInBits: sizeInBits)

      #expect(try X509Identity.signatureSchemes(for: key) == [scheme])
    }
  }

  @Test("A key produces a verifiable signature for every scheme it advertises")
  func signsEverySchemeItAdvertises() throws {
    let keys: [(type: CFString, sizeInBits: Int)] = [
      (kSecAttrKeyTypeRSA, 2048),
      (kSecAttrKeyTypeECSECPrimeRandom, 256),
    ]

    for (type, sizeInBits) in keys {
      let key = try makeKey(type: type, sizeInBits: sizeInBits)
      let identity = try X509ClientIdentity(certificateChain: [], privateKey: key)
      let publicKey = try #require(SecKeyCopyPublicKey(key))

      for scheme in identity.signatureSchemes {
        let signature = try identity.sign(scheme: scheme, message: Self.message)

        #expect(
          SecKeyVerifySignature(
            publicKey,
            scheme.securityAlgorithm,
            Self.message as CFData,
            signature as CFData,
            nil))
      }
    }
  }

  /// Guards against the schemes collapsing onto one algorithm, which a sign-then-verify
  /// round trip cannot catch because it would use the same wrong algorithm twice.
  @Test("A signature does not verify under a different scheme")
  func signatureDoesNotVerifyUnderAnotherScheme() throws {
    let key = try makeKey(type: kSecAttrKeyTypeRSA, sizeInBits: 2048)
    let identity = try X509ClientIdentity(certificateChain: [], privateKey: key)
    let publicKey = try #require(SecKeyCopyPublicKey(key))

    let signature = try identity.sign(scheme: .rsaPssSha256, message: Self.message)

    #expect(
      !SecKeyVerifySignature(
        publicKey,
        X509SignatureScheme.rsaPssSha384.securityAlgorithm,
        Self.message as CFData,
        signature as CFData,
        nil))
  }

  @Test("Signing with a scheme the key cannot use fails")
  func signingWithAnUnsupportedSchemeFails() throws {
    let key = try makeKey(type: kSecAttrKeyTypeECSECPrimeRandom, sizeInBits: 256)
    let identity = try X509ClientIdentity(certificateChain: [], privateKey: key)

    #expect(throws: X509IdentityError.self) {
      try identity.sign(scheme: .rsaPssSha256, message: Self.message)
    }
  }

  @Test("Every scheme maps to its Security.framework algorithm")
  func schemesMapToSecurityAlgorithms() {
    let expected: [(scheme: X509SignatureScheme, algorithm: SecKeyAlgorithm)] = [
      (.rsaPkcs1Sha256, .rsaSignatureMessagePKCS1v15SHA256),
      (.rsaPkcs1Sha384, .rsaSignatureMessagePKCS1v15SHA384),
      (.rsaPkcs1Sha512, .rsaSignatureMessagePKCS1v15SHA512),
      (.rsaPssSha256, .rsaSignatureMessagePSSSHA256),
      (.rsaPssSha384, .rsaSignatureMessagePSSSHA384),
      (.rsaPssSha512, .rsaSignatureMessagePSSSHA512),
      (.ecdsaNistp256Sha256, .ecdsaSignatureMessageX962SHA256),
      (.ecdsaNistp384Sha384, .ecdsaSignatureMessageX962SHA384),
      (.ecdsaNistp521Sha512, .ecdsaSignatureMessageX962SHA512),
    ]

    for (scheme, algorithm) in expected {
      #expect(scheme.securityAlgorithm == algorithm)
    }
  }

  @Test("A configuration without an identity reference yields no certificate")
  func noReferenceYieldsNoCertificate() throws {
    #expect(try X509Identity.leafCertificate(persistentReference: nil) == nil)
  }

  private static let message = Data("firezone mutual-TLS handshake".utf8)

  /// Generates a key that lives only for the test: without `kSecAttrIsPermanent` the key
  /// never reaches a keychain, so these tests need no keychain access and no entitlements.
  private func makeKey(type: CFString, sizeInBits: Int) throws -> SecKey {
    let attributes: [CFString: Any] = [
      kSecAttrKeyType: type,
      kSecAttrKeySizeInBits: sizeInBits,
    ]

    return try #require(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
  }
}
