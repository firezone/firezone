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
      (.empty, "Empty"),
      (.tooLong, "Too long"),
      (.ambiguous, "Ambiguous"),
      (.placeholderIdentifier, "Placeholder identifier"),
      (.unknownAttribute, "Unrecognized attribute"),
      (.notYetValid, "Not yet valid"),
      (.expired, "Expired"),
      (.missingClientAuthEku, "Missing client authentication EKU"),
      (.digitalSignatureNotAllowed, "Digital signature not allowed"),
    ]

    for (error, label) in labels {
      #expect(error.label == label)
    }
  }
}
