//
//  TelemetryTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
import Testing

@testable import FirezoneKit

@Suite("Telemetry Tests")
struct TelemetryTests {
  @Test("An error without a description is named by its type and case")
  func namesUndescribedErrorsByTypeAndCase() {
    let withPayload = CreateZipError.urlNotADirectory(URL(fileURLWithPath: "/Users/alice/logs"))
    let withoutPayload = SemanticVersion.Error.invalidVersionString

    #expect(Telemetry.fallbackDescription(of: withPayload) == "CreateZipError.urlNotADirectory")
    #expect(
      Telemetry.fallbackDescription(of: withoutPayload)
        == "SemanticVersion.Error.invalidVersionString")
  }

  @Test("An error with a description keeps it")
  func keepsExistingDescriptions() {
    let localized = VPNConfigurationManagerError.managerNotInitialized
    let cocoa = NSError(domain: NSCocoaErrorDomain, code: NSCoderReadCorruptError)

    #expect(Telemetry.fallbackDescription(of: localized) == nil)
    #expect(Telemetry.fallbackDescription(of: cocoa) == nil)
  }
}
