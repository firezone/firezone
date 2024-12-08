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
    case unableToOpenWriteStream
    case unableToOpenCompressionStream
    case unableToOpenEncodeStream
    case unableToDefineHeaderKeys
  }

  public init() {}

  public func start(
    source directory: URL,
    to file: URL
  ) throws {
    guard let path = FilePath(file),
          let stream = ArchiveByteStream.fileStream(
            path: path,
            mode: .writeOnly,
            options: [.create],
            permissions: FilePermissions(rawValue: 0o644)
          )
    else {
      throw CompressionError.unableToOpenWriteStream
    }

    try compress(source: directory, writeStream: stream)
  }

  public func start(
    source directory: URL,
    to byteStream: TunnelArchiveByteStream
  ) throws {
    guard let stream = ArchiveByteStream.customStream(
      instance: byteStream
    )
    else {
      throw CompressionError.unableToOpenWriteStream
    }

    try compress(source: directory, writeStream: stream)
  }

  // Compress to a given writeStream which was opened either from a FilePath or
  // TunnelArchiveByteStream
  private func compress(
    source directory: URL,
    writeStream: ArchiveByteStream
  ) throws {
    let compressionStream = try openCompressionStream(writeStream)
    let encodeStream = try openEncodeStream(compressionStream)
    let keySet = try defineHeaderKeys()

    guard let sourcePath = FilePath(directory)
    else {
      throw CompressionError.unableToReadSourceDirectory
    }

    try encodeStream.writeDirectoryContents(
      archiveFrom: sourcePath,
      keySet: keySet
    )

    try? encodeStream.close()
    try? compressionStream.close()
    try? writeStream.close()
  }

  private func openCompressionStream(_ writeStream: ArchiveByteStream) throws -> ArchiveByteStream {
    guard let stream = ArchiveByteStream.compressionStream(
      using: .lzfse,
      writingTo: writeStream
    )
    else {
      throw CompressionError.unableToOpenCompressionStream
    }

    return stream
  }

  private func openEncodeStream(
    _ compressionStream: ArchiveByteStream
  ) throws -> ArchiveStream {
    guard let stream = ArchiveStream.encodeStream(writingTo: compressionStream)
    else {
      throw CompressionError.unableToOpenEncodeStream
    }

    return stream
  }

  private func defineHeaderKeys() throws -> ArchiveHeader.FieldKeySet {
    let keys = "TYP,PAT,LNK,DEV,DAT,UID,GID,MOD,FLG,MTM,BTM,CTM"
    guard let keySet = ArchiveHeader.FieldKeySet(keys)
    else {
      throw CompressionError.unableToDefineHeaderKeys
    }

    return keySet
  }
}
