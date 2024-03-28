//
//  LogCompressor.swift
//
//
//  Created by Jamil Bou Kheir on 3/28/24.
//

import AppleArchive
import Foundation
import System

struct LogCompressor {
  private let logger: AppLogger
  private let destinationURL: URL?
  let fileName: String

  init(logger: AppLogger, destinationURL: URL? = nil) {
    let dateFormatter = ISO8601DateFormatter()
    dateFormatter.formatOptions = [.withFullDate, .withTime, .withTimeZone]
    let timeStampString = dateFormatter.string(from: Date())
    self.fileName = "firezone_logs_\(timeStampString).aar"
    self.logger = logger
    self.destinationURL = destinationURL
  }

  public func compressFolder(destinationURL: URL? = nil) async throws {
    try await compressFolderReturningURL(destinationURL: destinationURL)
  }

  @discardableResult
  public func compressFolderReturningURL(destinationURL: URL? = nil) async throws -> URL? {
    guard let logFilesFolderURL = SharedAccess.logFolderURL,
      let logFilesFolderPath = FilePath(logFilesFolderURL)
    else {
      throw SettingsViewError.logFolderIsUnavailable
    }

    let fileManager = FileManager.default
    let fileURL =
      destinationURL
      ?? fileManager.temporaryDirectory.appendingPathComponent(fileName)

    // Remove logfile if it happens to exist
    try? fileManager.removeItem(at: fileURL)

    // Create the file stream to write the compressed file
    guard let filePath = FilePath(fileURL),
      let writeFileStream = ArchiveByteStream.fileStream(
        path: filePath,
        mode: .writeOnly,
        options: [.create],
        permissions: FilePermissions(rawValue: 0o644))
    else {
      logger.error("\(#function): Couldn't create the file stream")
      return nil
    }
    defer {
      try? writeFileStream.close()
    }

    // Create the compression stream
    guard
      let compressStream = ArchiveByteStream.compressionStream(
        using: .lzfse,
        writingTo: writeFileStream)
    else {
      logger.error("\(#function): Couldn't create the compression stream")
      return nil
    }
    defer {
      try? compressStream.close()
    }

    // Create the encoding stream
    guard let encodeStream = ArchiveStream.encodeStream(writingTo: compressStream) else {
      logger.error("\(#function): Couldn't create encoding stream")
      return nil
    }
    defer {
      try? encodeStream.close()
    }

    // Define header keys
    guard let keySet = ArchiveHeader.FieldKeySet("TYP,PAT,LNK,DEV,DAT,UID,GID,MOD,FLG,MTM,BTM,CTM")
    else {
      logger.error("\(#function): Couldn't define header keys")
      return nil
    }

    do {
      try encodeStream.writeDirectoryContents(
        archiveFrom: logFilesFolderPath,
        keySet: keySet)
    } catch {
      logger.error("Write directory contents failed.")
      return nil
    }

    return fileURL
  }
}
