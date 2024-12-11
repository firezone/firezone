//
//  LogExporter.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import AppleArchive
import Foundation
import System

struct LogExporter {

  static func export(to archiveURL: URL) {
    let fileManager = FileManager.default

    // 1. Remove existing archive
    try? fileManager.removeItem(at: archiveURL)

    do {
      try LogCompressor.compress(SharedAccess.appLogFolderURL!, to: archiveURL)
    } catch {
      Log.app.error("#\(#function)): \(error)")
    }
  }

  static func tempFile() -> URL {
    let dateFormatter = ISO8601DateFormatter()
    dateFormatter.formatOptions = [.withFullDate, .withTime, .withTimeZone]
    let timeStampString = dateFormatter.string(from: Date())
    let fileName = "firezone_logs_\(timeStampString).aar"
    let fileURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)

    return fileURL
  }
}

enum ExportError: Error {
  case archiveURLInvalid
}
