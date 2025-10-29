//
//  LogExporter.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import AppleArchive
import Foundation
import System

/// Convenience module for smoothing over the differences between exporting logs on macOS and iOS.
///
/// On macOS, we must export the app's log dir and tunnel's log dir separately to temp files, and then join
/// these into a final compressed archive saved at the user's specified location. This is because Apple Archive
/// compression APIs do not easily allow compressing from multiple disparate paths in one go; only a single
/// source directory is supported.
///
/// On iOS, the app process can compress the entire log directory itself, with no help from the tunnel process,
/// thus avoiding IPC. In this case we write directly to the provided archiveURL.

#if os(macOS)
  enum LogExporter {
    enum ExportError: Error {
      case invalidSourceDirectory
      case invalidFilePath
      case invalidFileHandle
    }

    static func export(
      to archiveURL: URL,
      with ipcClient: IPCClient
    ) async throws {
      guard let logFolderURL = SharedAccess.logFolderURL
      else {
        throw ExportError.invalidSourceDirectory
      }

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
      fileManager.createFile(atPath: tunnelLogURL.path, contents: nil)
      let fileHandle = try FileHandle(forWritingTo: tunnelLogURL)

      // 3. Await tunnel log export from tunnel process
      try await withCheckedThrowingContinuation { continuation in
        ipcClient.exportLogs(
          appender: { chunk in
            do {
              // Append each chunk to the archive
              try fileHandle.seekToEnd()
              fileHandle.write(chunk.data)

              if chunk.done {
                try fileHandle.close()
                continuation.resume()
              }

            } catch {
              try? fileHandle.close()

              continuation.resume(throwing: error)
            }
          },
          errorHandler: { error in
            continuation.resume(throwing: error)
          }
        )
      }

      // 4. Create app log archive
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
  enum LogExporter {
    enum ExportError: Error {
      case invalidSourceDirectory
      case invalidFilePath
      case documentDirectoryNotAvailable
    }

    static func export(to archiveURL: URL) async throws {
      guard let logFolderURL = SharedAccess.logFolderURL,
        let connlibLogFolderURL = SharedAccess.connlibLogFolderURL,
        let cacheFolderURL = SharedAccess.cacheFolderURL

      else {
        throw ExportError.invalidSourceDirectory
      }

      // Remove existing archive if it exists
      try? fileManager.removeItem(at: archiveURL)

      let latestSymlink = connlibLogFolderURL.appendingPathComponent("latest")
      let tempSymlink = cacheFolderURL.appendingPathComponent(
        "latest")

      // Move the `latest` symlink out of the way before creating the archive.
      // Apple's implementation of zip appears to not be able to handle symlinks well
      let _ = try? FileManager.default.moveItem(at: latestSymlink, to: tempSymlink)
      defer {
        let _ = try? FileManager.default.moveItem(at: tempSymlink, to: latestSymlink)
      }

      // Write final log archive
      try ZipService.createZip(
        source: logFolderURL,
        to: archiveURL
      )
    }

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
  private nonisolated(unsafe) static let fileManager = FileManager.default

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

  private static func toPath(_ url: URL) throws -> FilePath {
    guard let path = FilePath(url)
    else {
      throw ExportError.invalidFilePath
    }

    return path
  }
}
