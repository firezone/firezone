//
//  LogCompressor.swift
//
//
//  Created by Jamil Bou Kheir on 3/28/24.
//

import AppleArchive
import Foundation
import System

/// This module handles the business work of interacting with the AppleArchive framework to do the actual
/// compression. It's used from both the app and tunnel process in nearly the same way, save for how the
/// writeStream is opened.
///
/// In the tunnel process, the writeStream is a custom stream derived from our TunnelArchiveByteStream,
/// which keeps state around the writing of compressed bytes in order to handle sending chunks back to the
/// app process.
///
/// In the app process, the writeStream is derived from a passed file path where the Apple Archive
/// framework handles writing for us -- no custom byte stream instance is needed.
///
/// Once the writeStream is opened, the remaining operations are the same for both.
public struct LogCompressor {
  enum CompressionError: Error {
    case unableToReadSourceDirectory
    case unableToInitialize
  }

  public init() {}

  public func start(
    source directory: FilePath,
    to file: FilePath
  ) throws {
    let stream = ArchiveByteStream.fileStream(
      path: file,
      mode: .writeOnly,
      options: [.create],
      permissions: FilePermissions(rawValue: 0o644)
    )

    try compress(source: directory, writeStream: stream)
  }

  // Compress to a given writeStream which was opened either from a FilePath or
  // TunnelArchiveByteStream
  private func compress(
    source path: FilePath,
    writeStream: ArchiveByteStream?
  ) throws {
    let headerKeys = "TYP,PAT,LNK,DEV,DAT,UID,GID,MOD,FLG,MTM,BTM,CTM"

    guard let writeStream = writeStream,
          let compressionStream =
            ArchiveByteStream.compressionStream(
              using: .lzfse,
              writingTo: writeStream
            ),
          let encodeStream =
            ArchiveStream.encodeStream(
              writingTo: compressionStream
            ),
          let keySet = ArchiveHeader.FieldKeySet(headerKeys)
    else {
      throw CompressionError.unableToInitialize
    }

    defer {
      try? encodeStream.close()
      try? compressionStream.close()
      try? writeStream.close()
    }

    try encodeStream.writeDirectoryContents(
      archiveFrom: path,
      keySet: keySet
    )
  }
}
