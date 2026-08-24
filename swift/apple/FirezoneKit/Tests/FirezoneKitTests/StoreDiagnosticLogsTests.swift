//
//  StoreDiagnosticLogsTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

#if os(macOS)
  import Foundation
  import Testing

  @testable import FirezoneKit

  /// Exercises the diagnostic-log operations end to end against the mocked extension:
  /// through `Store`, `IPCClient`'s provider messages, and the mock session's answers.
  ///
  /// Serialised because every `Store` loads into the process-wide `Configuration`.
  @MainActor
  @Suite("Store diagnostic logs", .serialized)
  struct StoreDiagnosticLogsTests {
    /// The mock provider reports 30 MB; the mock log directory holds two 49-byte lines.
    private static let mockLogBytes: UInt64 = 30_000_000 + 98

    @Test("sums the app logs and the provider's report")
    func sumsAppAndProviderSizes() async throws {
      let store = Store.mock()
      try await store.installVPNConfiguration()

      let size = await store.logDirectorySize()

      #expect(size == Self.mockLogBytes)
    }

    @Test("reports no size without a VPN configuration")
    func reportsNoSizeWithoutConfiguration() async throws {
      let store = Store.mock()

      let size = await store.logDirectorySize()

      #expect(size == nil)
    }

    @Test("clearing empties both sides")
    func clearingEmptiesBothSides() async throws {
      let store = Store.mock()
      try await store.installVPNConfiguration()

      try await store.clearLogs()

      let size = await store.logDirectorySize()
      #expect(size == 0)
    }

    @Test("exports an archive holding the app and tunnel logs")
    func exportsAnArchive() async throws {
      let store = Store.mock()
      try await store.installVPNConfiguration()
      let destination = FileManager.default.temporaryDirectory
        .appendingPathComponent("firezone-export-\(UUID().uuidString).zip")
      defer { try? FileManager.default.removeItem(at: destination) }

      try await store.exportLogs(to: destination)

      let archive = try Data(contentsOf: destination)
      #expect(archive.prefix(4) == Data([0x50, 0x4B, 0x03, 0x04]))
      // ZIP entry names are stored uncompressed, so the members are findable as bytes.
      #expect(archive.firstRange(of: Data("tunnel.zip".utf8)) != nil)
      #expect(archive.firstRange(of: Data("app.zip".utf8)) != nil)
    }

    @Test("the view model publishes the size and the clearing state")
    func viewModelDrivesTheLogsState() async throws {
      let store = Store.mock()
      try await store.installVPNConfiguration()
      let model = SettingsViewModel(store: store)

      model.refreshLogDirectorySize()
      try await waitUntil { model.logDirectorySizeText != nil }
      let sizeBeforeClear = model.logDirectorySizeText
      #expect(sizeBeforeClear != "Unknown")

      model.clearLogs()
      #expect(model.isClearingLogs)

      try await waitUntil { !model.isClearingLogs }
      try await waitUntil { model.logDirectorySizeText != nil }
      #expect(model.logDirectorySizeText != sizeBeforeClear)
    }

    @Test("the view model reports an unknown size without a store")
    func viewModelWithoutStoreReportsUnknown() async throws {
      let model = SettingsViewModel(store: nil)

      model.refreshLogDirectorySize()

      try await waitUntil { model.logDirectorySizeText != nil }
      #expect(model.logDirectorySizeText == "Unknown")
    }

    private func waitUntil(
      timeout: Duration = .seconds(5),
      _ condition: @MainActor () -> Bool
    ) async throws {
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: timeout)

      while !condition() {
        guard clock.now < deadline else { throw TimeoutError() }
        try await Task.sleep(for: .milliseconds(10))
      }
    }

    private struct TimeoutError: Error {}
  }
#endif
