//
//  LogCompressor.swift
//
//
//  Created by Jamil Bou Kheir on 3/28/24.
//

import AppleArchive
import Foundation
import System

/// Utility for creating an AAR archive given a Set of input URLs.
///
/// The URLs are read in parallel, compressed, and chunked back via the provided completionHandler.
///
/// The format provided to the completionHandler is:
///
public struct LogCompressor {

  public struct Chunk: Codable {
    var nextChunk: Bool
    var data: Data
  }

  public static func compress(_ url: URL, to archiveURL: URL) throws {

    // Define header keys
    guard let keySet = ArchiveHeader.FieldKeySet("TYP,PAT,LNK,DEV,DAT,UID,GID,MOD,FLG,MTM,BTM,CTM")
    else {
      Log.app.error("\(#function): Couldn't define header keys")

      return
    }

    var byteStream: TunnelArchiveByteStream?

    // Initialize our custom byte stream
    do {
      byteStream = try TunnelArchiveByteStream(archiveURL)
    } catch {
      Log.app.error("\(error)")
    }

    guard let byteStream = byteStream
    else {
      throw CompressionError.unableToOpenByteStream
    }

    // 3. Create a custom stream to receive compressed chunks
    guard let writeStream = ArchiveByteStream.customStream(
      instance: byteStream
    )
    else {
      throw CompressionError.unableToOpenWriteStream
    }
    defer {
      try? writeStream.close()
    }

    // 2. Create the compression stream
    guard
      let compressStream = ArchiveByteStream.compressionStream(
        using: .lzfse,
        writingTo: writeStream)
    else {
      throw CompressionError.unableToOpenCompressionStream
    }
    defer {
      try? compressStream.close()
    }

    // 3. Create the encoding stream
    guard let encodeStream = ArchiveStream.encodeStream(writingTo: compressStream)
    else {
      throw CompressionError.unableToOpenEncodingStream
    }
    defer {
      try? encodeStream.close()
    }

    guard let filePath = FilePath(url)
    else {
      throw CompressionError.archiveURLInvalid
    }

    try encodeStream.writeDirectoryContents(
        archiveFrom: filePath,
        keySet: keySet)
  }
}

enum CompressionError: Error {
  case archiveURLInvalid
  case unableToOpenByteStream
  case unableToOpenWriteStream
  case unableToOpenCompressionStream
  case unableToOpenEncodingStream
  case unableToWriteData
}
