//
//  TunnelArchiveByteStream.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import AppleArchive
import System
import Foundation
import FirezoneKit

/// We must enable the app sandbox when distributing the macOS client in the App Store. Since the tunnel
/// process runs as root, this makes sharing log files between the app process (running as the
/// logged in user) and tunnel process (running as root) tricky. The app process can't read or write directly to
/// the tunnel's log directory, and vice-versa for the tunnel process and app log directory.
///
/// The way we overcome this is IPC. This gets tricky with exporting logs, however. We can't
/// simply read the tunnel log directory into a giant buffer as this could be too large to send over the IPC
/// channel. Instead, we write the tunnel log archive to a temp file and then chunk it over with IPC.
///
/// Since the IPC channel is unidirectional from app -> tunnel, we use a simple data format to pass chunks
/// of this archive file from the tunnel back to the app, including a boolean `done` to indicate when the
/// archive is sent and the app should close its associated file.
///
/// Currently this limit is set to 1 MB (chosen somewhat arbitrarily based on limited information found on the
/// web), but can be easily enlarged in the future to reduce the number of IPC calls required to consume
/// the entire archive. The LZFSE compression algorithm used by default in the Apple Archive Framework is
/// quite efficient -- compression ratios for our logs can be as high as 100:1 using this format.
class TunnelLogArchive {
  enum ArchiveError: Error {
    case unableToWriteArchive
    case unableToReadArchive
  }

  let chunkSize = 1024 * 1024 // 1 MiB
  let encoder = PropertyListEncoder()
  let archiveURL = FileManager
    .default
    .temporaryDirectory
    .appendingPathComponent("logs.aar")

  var offset: UInt64 = 0
  var fileHandle: FileHandle?
  var source: FilePath

  init(source: FilePath) {
    self.source = source
  }

  deinit {
    cleanup()
  }

  func archive() throws {
    guard let archivePath = FilePath(self.archiveURL)
    else {
      throw ArchiveError.unableToWriteArchive
    }

    try? FileManager.default.removeItem(at: self.archiveURL)

    try LogCompressor().start(
      source: source,
      to: archivePath
    )
  }

  func readChunk() throws -> Data {
    if self.fileHandle == nil {
      // Open the file for reading
      try self.fileHandle = FileHandle(forReadingFrom: archiveURL)
    }

    guard let fileHandle = self.fileHandle
    else {
      throw ArchiveError.unableToReadArchive
    }

    // Read archive at offset up to chunkSize bytes
    try fileHandle.seek(toOffset: self.offset)
    guard let data = try fileHandle.read(upToCount: chunkSize)
    else {
      throw ArchiveError.unableToReadArchive
    }

    self.offset += UInt64(data.count)

    let chunk = LogChunk(
      done: data.count < chunkSize, // we're done if we read less than chunkSize
      data: data
    )

    if chunk.done {
      cleanup()
    }

    return try encoder.encode(chunk)
  }

  func cleanup() {
    try? self.fileHandle?.close()
    try? FileManager.default.removeItem(at: archiveURL)

    self.offset = 0
    self.fileHandle = nil
  }
}
