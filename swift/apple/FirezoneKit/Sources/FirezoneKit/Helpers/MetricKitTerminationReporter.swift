//
//  MetricKitTerminationReporter.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Darwin
import Foundation
import Sentry

#if canImport(MetricKit)
  import MetricKit

  final class MetricKitTerminationReporter: NSObject, MXMetricManagerSubscriber {
    static let appBundleIdentifier = "dev.firezone.firezone"
    static let diagnosticExceptionType = "AppleProcessTermination"
    static let diagnosticMechanismType = "apple_process_termination"

    private static let processedDiagnosticSignaturesKey =
      "processedMetricKitTerminationDiagnosticSignatures"
    private static let maxStoredSignatures = 50

    private let defaults: UserDefaults
    private let metricManager: MXMetricManager
    private let stateLock = NSLock()

    private var isStarted = false

    init(
      defaults: UserDefaults = .standard,
      metricManager: MXMetricManager = .shared
    ) {
      self.defaults = defaults
      self.metricManager = metricManager
      super.init()
    }

    func startIfSupported() {
      guard Self.isSupportedInCurrentProcess else { return }
      start()
    }

    private func start() {
      let shouldStart = stateLock.withLock {
        if isStarted {
          return false
        }

        isStarted = true
        return true
      }

      guard shouldStart else { return }

      metricManager.add(self)
      processDiagnosticPayloads(metricManager.pastDiagnosticPayloads)
    }

    static var isSupportedInCurrentProcess: Bool {
      Bundle.main.bundleIdentifier == appBundleIdentifier
    }

    static func shouldReportTerminationDiagnostic(
      signal: NSNumber?
    ) -> Bool {
      return signal?.int32Value == SIGKILL
    }

    static func formatHex(_ value: NSNumber?) -> String? {
      guard let value else { return nil }
      return String(format: "0x%llx", value.uint64Value)
    }

    static func formatTimestamp(_ date: Date) -> String {
      ISO8601DateFormatter().string(from: date)
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) {
      processDiagnosticPayloads(payloads)
    }

    private func processDiagnosticPayloads(_ payloads: [MXDiagnosticPayload]) {
      for payload in payloads {
        for diagnostic in payload.crashDiagnostics ?? [] {
          process(diagnostic: diagnostic, payload: payload)
        }
      }
    }

    private func process(diagnostic: MXCrashDiagnostic, payload: MXDiagnosticPayload) {
      guard
        Self.shouldReportTerminationDiagnostic(
          signal: diagnostic.signal
        )
      else {
        return
      }

      let signature = diagnosticSignature(diagnostic: diagnostic, payload: payload)

      guard
        markSignatureAsProcessed(
          signature,
          storageKey: Self.processedDiagnosticSignaturesKey
        )
      else {
        Log.debug("Skipping duplicate MetricKit termination diagnostic: \(signature)")
        return
      }

      captureTerminationDiagnostic(diagnostic: diagnostic, payload: payload)
    }

    private func diagnosticSignature(
      diagnostic: MXCrashDiagnostic,
      payload: MXDiagnosticPayload
    ) -> String {
      [
        diagnostic.applicationVersion,
        Self.formatTimestamp(payload.timeStampBegin),
        Self.formatTimestamp(payload.timeStampEnd),
        diagnostic.terminationReason ?? "nil",
        Self.formatHex(diagnostic.exceptionCode) ?? "nil",
        Self.formatHex(diagnostic.exceptionType) ?? "nil",
        diagnostic.signal?.stringValue ?? "nil",
      ]
      .joined(separator: "|")
    }

    private func markSignatureAsProcessed(
      _ signature: String,
      storageKey: String
    ) -> Bool {
      stateLock.withLock {
        var signatures = defaults.stringArray(forKey: storageKey) ?? []

        guard !signatures.contains(signature) else {
          return false
        }

        signatures.append(signature)
        if signatures.count > Self.maxStoredSignatures {
          signatures.removeFirst(signatures.count - Self.maxStoredSignatures)
        }

        defaults.set(signatures, forKey: storageKey)
        return true
      }
    }

    private func captureTerminationDiagnostic(
      diagnostic: MXCrashDiagnostic,
      payload: MXDiagnosticPayload
    ) {
      let event = Event(level: .fatal)
      event.timestamp = payload.timeStampEnd
      event.logger = "apple.metric_kit.termination"
      var tags = [
        "event_source": "metrickit",
        "metric_kit_payload_type": "diagnostic",
        "metric_kit_diagnostic": "crash",
        "termination_signal": String(SIGKILL),
      ]

      if let exceptionCode = Self.formatHex(diagnostic.exceptionCode) {
        tags["termination_exception_code"] = exceptionCode
      }

      event.fingerprint = [
        "apple-process-termination",
        diagnostic.signal?.stringValue ?? "unknown",
        Self.formatHex(diagnostic.exceptionCode) ?? diagnostic.terminationReason ?? "unknown",
      ]
      event.tags = tags
      event.extra = diagnosticExtra(
        diagnostic: diagnostic,
        payloadStart: payload.timeStampBegin,
        payloadEnd: payload.timeStampEnd,
        metaData: diagnostic.metaData
      )

      let exception = Exception(
        value: exceptionValue(for: diagnostic),
        type: Self.diagnosticExceptionType
      )
      let mechanism = Mechanism(type: Self.diagnosticMechanismType)
      mechanism.handled = false
      mechanism.synthetic = true
      mechanism.data = [
        "metric_kit_payload_start": Self.formatTimestamp(payload.timeStampBegin),
        "metric_kit_payload_end": Self.formatTimestamp(payload.timeStampEnd),
      ]
      exception.mechanism = mechanism
      event.exceptions = [exception]

      let diagnosticPayload = payload.jsonRepresentation()
      SentrySDK.capture(event: event) { scope in
        scope.addAttachment(
          Attachment(data: diagnosticPayload, filename: "MXDiagnosticPayload.json")
        )
      }

      Log.warning(
        "Captured MetricKit termination diagnostic reason=\(diagnostic.terminationReason ?? "nil") signal=\(diagnostic.signal?.stringValue ?? "nil") exception_code=\(Self.formatHex(diagnostic.exceptionCode) ?? "nil")"
      )
    }

    private func diagnosticExtra(
      diagnostic: MXCrashDiagnostic,
      payloadStart: Date,
      payloadEnd: Date,
      metaData: MXMetaData
    ) -> [String: Any] {
      var extra: [String: Any] = [
        "metric_kit_payload_start": Self.formatTimestamp(payloadStart),
        "metric_kit_payload_end": Self.formatTimestamp(payloadEnd),
        "diagnostic_application_version": diagnostic.applicationVersion,
      ]

      if let terminationReason = diagnostic.terminationReason {
        extra["termination_reason"] = terminationReason
      }

      if let exceptionType = Self.formatHex(diagnostic.exceptionType) {
        extra["exception_type"] = exceptionType
      }

      if let exceptionCode = Self.formatHex(diagnostic.exceptionCode) {
        extra["exception_code"] = exceptionCode
      }

      if let signal = diagnostic.signal?.intValue {
        extra["signal"] = signal
      }

      add(metaData: metaData, to: &extra)
      return extra
    }

    private func add(metaData: MXMetaData, to extra: inout [String: Any]) {
      extra["os_version"] = metaData.osVersion
      extra["device_type"] = metaData.deviceType
      extra["application_build_version"] = metaData.applicationBuildVersion
      extra["region_format"] = metaData.regionFormat

      if #available(iOS 14.0, macOS 12.0, *) {
        extra["platform_architecture"] = metaData.platformArchitecture
      }

      if #available(iOS 17.0, macOS 14.0, *) {
        extra["low_power_mode_enabled"] = metaData.lowPowerModeEnabled
        extra["is_testflight_app"] = metaData.isTestFlightApp
        if metaData.pid >= 0 {
          extra["pid"] = Int(metaData.pid)
        }
      }
    }

    private func exceptionValue(for diagnostic: MXCrashDiagnostic) -> String {
      let reason = diagnostic.terminationReason ?? "unknown"
      let signal = diagnostic.signal?.stringValue ?? "unknown"
      let exceptionCode = Self.formatHex(diagnostic.exceptionCode) ?? "unknown"

      return
        "Apple terminated the app (termination_reason=\(reason), signal=\(signal), exception_code=\(exceptionCode))."
    }
  }

  extension MetricKitTerminationReporter: @unchecked Sendable {}
#endif
