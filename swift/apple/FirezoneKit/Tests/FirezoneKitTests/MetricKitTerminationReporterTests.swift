//
//  MetricKitTerminationReporterTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Darwin
import Foundation
import Testing

@testable import FirezoneKit

#if canImport(MetricKit)
  @Suite("MetricKit Termination Reporter Tests")
  struct MetricKitTerminationReporterTests {

    @Test("Does not report diagnostics without a signal")
    func rejectsMissingSignal() {
      #expect(
        !MetricKitTerminationReporter.shouldReportTerminationDiagnostic(
          signal: nil
        )
      )
    }

    @Test("Reports diagnostics with SIGKILL signal")
    func reportsSigkillSignal() {
      #expect(
        MetricKitTerminationReporter.shouldReportTerminationDiagnostic(
          signal: NSNumber(value: SIGKILL)
        )
      )
    }

    @Test("Does not report non-termination crash diagnostics")
    func rejectsNonTerminationCrashDiagnostics() {
      #expect(
        !MetricKitTerminationReporter.shouldReportTerminationDiagnostic(
          signal: NSNumber(value: SIGABRT)
        )
      )
    }

    @Test("Formats numeric values as lowercase hex strings")
    func formatsHexValues() {
      #expect(
        MetricKitTerminationReporter.formatHex(NSNumber(value: 0x1234 as UInt64)) == "0x1234"
      )
    }
  }
#endif
