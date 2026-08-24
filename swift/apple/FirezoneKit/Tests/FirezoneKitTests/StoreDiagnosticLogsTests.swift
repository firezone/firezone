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
  /// Safe to run in parallel: each mock `Store` owns its own `Configuration` and an
  /// ephemeral `UserDefaults` suite (see `Store.mock`).
  @MainActor
  @Suite("Store diagnostic logs")
  struct StoreDiagnosticLogsTests {
    /// What the mock provider reports over IPC.
    private static let providerLogBytes: UInt64 = 30_000_000

    @Test("reports exactly the provider's size for an empty app log directory")
    func reportsTheProviderSize() async throws {
      let emptyDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("firezone-empty-logs-\(UUID().uuidString)")
      try FileManager.default.createDirectory(at: emptyDirectory, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: emptyDirectory) }

      let store = Store.mock(logDirectory: emptyDirectory)
      try await store.installVPNConfiguration()

      let size = await store.logDirectorySize()

      #expect(size == Self.providerLogBytes)
    }

    @Test("counts the app logs into the total")
    func countsAppLogsIntoTheTotal() async throws {
      let store = Store.mock()
      try await store.installVPNConfiguration()

      // The exact app-side number depends on filesystem allocation, so only the
      // provider baseline is pinned.
      let size = try #require(await store.logDirectorySize())
      #expect(size > Self.providerLogBytes)
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
