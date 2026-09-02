//
//  LogExporter.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import AppleArchive
import Foundation
@preconcurrency import NetworkExtension
import SystemPackage

/// Convenience module for smoothing over the differences between exporting logs from a
/// bundled provider and from a system extension.
///
/// A bundled provider writes into the same group container as the app, so the app
/// compresses the whole log directory itself with no help from the tunnel process, thus
/// avoiding IPC. Every iOS build and the Mac App Store build take this path.
///
/// A system extension runs as root and so writes into a different group container. Its
/// logs have to be fetched over IPC into a temp file and joined with the app's own
/// archive, because the Apple Archive compression APIs only take a single source
/// directory.
enum LogExporter {
  enum ExportError: Error {
    case invalidSourceDirectory
    case invalidFileHandle
    case documentDirectoryNotAvailable
  }

  // @concurrent: zipping a large log tree must not run on the main actor.
  /// Compresses `logFolderURL` straight into `archiveURL`, with no help from the tunnel.
  @concurrent
  static func export(to archiveURL: URL, from logFolderURL: URL) async throws {
    // Remove existing archive if it exists
    try? fileManager.removeItem(at: archiveURL)

    // Write final log archive
    try ZipService.createZip(
      source: logFolderURL,
      to: archiveURL
    )
  }
}

#if os(macOS)
  extension LogExporter {
    /// Joins the app's logs with the ones the system extension hands over IPC.
    @MainActor
    static func export(
      to archiveURL: URL,
      from logFolderURL: URL,
      session: any TunnelSessionProtocol
    ) async throws {
      // 1. Create a temporary working directory to stage app and tunnel archives
      let sharedLogFolderURL = fileManager
        .temporaryDirectory
        .appendingPathComponent("firezone_logs")
      try? fileManager.removeItem(at: sharedLogFolderURL)
      try fileManager.createDirectory(
        at: sharedLogFolderURL,
        withIntermediateDirectories: true
      )

      // 2. Create tunnel log archive from tunnel process
      let tunnelLogURL =
        sharedLogFolderURL
        .appendingPathComponent("tunnel.zip")
      let fd = try FileDescriptor.open(
        FilePath(tunnelLogURL.path),
        .writeOnly,
        options: [.create, .truncate],
        permissions: [.ownerReadWrite, .groupRead, .otherRead]
      )
      defer { try? fd.close() }

      // 3. Await tunnel log export from tunnel process
      try await IPCClient.exportLogs(session: session, fd: fd)

      // 4. Archive the app logs and join both into the final archive
      try await archive(
        appLogs: logFolderURL,
        staging: sharedLogFolderURL,
        tunnelArchive: tunnelLogURL,
        to: archiveURL
      )
    }

    // @concurrent: zipping a large log tree must not run on the main actor.
    @concurrent
    private static func archive(
      appLogs logFolderURL: URL,
      staging sharedLogFolderURL: URL,
      tunnelArchive tunnelLogURL: URL,
      to archiveURL: URL
    ) async throws {
      let appLogURL = sharedLogFolderURL.appendingPathComponent("app.zip")
      try ZipService.createZip(
        source: logFolderURL,
        to: appLogURL
      )

      // Remove existing archive if it exists
      try? fileManager.removeItem(at: archiveURL)

      // Write final log archive
      try ZipService.createZip(
        source: sharedLogFolderURL,
        to: archiveURL
      )

      // Remove intermediate log archives
      try? fileManager.removeItem(at: tunnelLogURL)
      try? fileManager.removeItem(at: appLogURL)
    }
  }
#endif

#if os(iOS)
  extension LogExporter {
    static func tempFile() throws -> URL {
      let fileName = "firezone_logs_\(now()).zip"

      // The share sheet can read from the documents directory, but not the temp directory, so use the former.
      guard let documentsPath = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first
      else {
        throw ExportError.documentDirectoryNotAvailable
      }

      return documentsPath.appendingPathComponent(fileName)
    }
  }
#endif

extension LogExporter {
  /// Thread-safe: FileManager.default is documented as thread-safe by Apple.
  /// Reference: https://developer.apple.com/documentation/foundation/filemanager
  nonisolated(unsafe) private static let fileManager = FileManager.default

  static func now() -> String {
    let dateFormatter = ISO8601DateFormatter()
    dateFormatter.formatOptions = [
      .withFullDate,
      .withTime,
      .withTimeZone,
    ]
    let timeStampString = dateFormatter.string(from: Date())

    return timeStampString
  }
}
