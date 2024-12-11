//
//  LogExporter.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import AppleArchive
import Foundation
import System

struct LogExporter {
  enum Error: Swift.Error {
    case archiveURLInvalid
    case unableToOpenWriteStream
    case unableToOpenCompressionStream
  }

  static func export(_ urls: Set<URL>, to archiveURL: URL) async throws -> URL {
    let fileManager = FileManager.default

    // 1. Remove existing archive
    try? fileManager.removeItem(at: archiveURL)

    // 2. Get a filePath
    guard let filePath = FilePath(archiveURL)
    else {
      throw Error.archiveURLInvalid
    }

    // 3. Create the compression stream
    guard let compressionStream = ArchiveByteStream.fileStream()(
      using: .lzfse,
      path: filePath,
      mode: .writeOnly,
      options: [.create],
      permissions: FilePermissions(rawValue: 0o644))
    else {
      throw Error.unableToOpenWriteStream
    }
    defer {
      try? writeFileStream.close()
    }

    // 2. Create the compression stream
    guard
      let compressStream = ArchiveByteStream.compressionStream(
        using: .lzfse,
        writingTo: writeFileStream)
    else {
      throw Error.unableToOpenCompressionStream
    }
    defer {
      try? compressStream.close()
    }

    // 3. Create the encoding stream
    guard let encodeStream = ArchiveStream.encodeStream(writingTo: compressStream) else {
      Log.app.error("\(#function): Couldn't create encoding stream")
      return nil
    }
    defer {
      try? encodeStream.close()
    }

    for url in urls {
      LogCompressor.compress(
        }

        return archiveURL
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
