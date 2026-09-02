//
//  DeviceTrustValidationErrorTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Testing

@testable import FirezoneKit

@Suite("Device Trust Validation Error Tests")
struct DeviceTrustValidationErrorTests {
  @Test("Validation errors use concise display labels")
  func usesConciseDisplayLabels() {
    let labels: [(DeviceTrustValidationError, String)] = [
      (.empty, "empty"),
      (.tooLong, "too long"),
      (.ambiguous, "ambiguous"),
      (.placeholderIdentifier, "placeholder identifier"),
      (.unknownAttribute, "unrecognized attribute"),
      (.notYetValid, "not yet valid"),
      (.expired, "expired"),
      (.missingClientAuthEku, "missing client authentication EKU"),
      (.digitalSignatureNotAllowed, "digital signature not allowed"),
    ]

    for (error, label) in labels {
      #expect(error.label == label)
    }
  }
}
