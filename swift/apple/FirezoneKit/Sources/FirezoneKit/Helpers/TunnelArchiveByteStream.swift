//
//  TunnelArchiveByteStream.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import AppleArchive
import System
import Foundation

class TunnelArchiveByteStream: ArchiveByteStreamProtocol {
  private var fileHandle: FileHandle
  private let fileManager = FileManager.default

  init (_ fileURL: URL) throws {
    Log.app.debug("\(#function): \(fileURL.absoluteString)")

    if !fileManager.fileExists(atPath: fileURL.path) {
      fileManager.createFile(atPath: fileURL.path, contents: nil)
    }

    self.fileHandle = try FileHandle(forWritingTo: fileURL)
  }

  func read(into buffer: UnsafeMutableRawBufferPointer) -> Int {
    Log.app.log("\(#function): \(buffer.count) bytes")

    return buffer.count
  }

  func read(into buffer: UnsafeMutableRawBufferPointer, atOffset: Int64) -> Int {
    Log.app.log("\(#function): \(buffer.count) bytes at offset: \(atOffset)")

    return buffer.count
  }

  func write(from buffer: UnsafeRawBufferPointer) -> Int {
    Log.app.log("\(#function): \(buffer) bytes")

    do {
      // Move the file pointer to the end for appending
      try fileHandle.seekToEnd()

      // Write data to the file
      let data = Data(buffer)
      try fileHandle.write(contentsOf: data)

      return buffer.count
      
    } catch {

      Log.app.error("Failed to write to file: \(error)")

      return 0
    }
  }

  func write(from: UnsafeRawBufferPointer, atOffset: Int64) -> Int {
    Log.app.log("\(#function): \(from.count) bytes at offset: \(atOffset)")

    return from.count
  }

  func seek(toOffset: Int64, relativeTo: FileDescriptor.SeekOrigin) -> Int64 {
    Log.app.log("\(#function): to offset \(toOffset) relative to \(relativeTo)")

    return 0
  }

  func cancel() {
    Log.app.log("\(#function)")
  }

  func close() throws {
    Log.app.log("\(#function)")
  }
}
