//
//  TunnelArchiveByteStream.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import AppleArchive
import System

class TunnelArchiveByteStream: ArchiveByteStreamProtocol {
  func read(into: UnsafeMutableRawBufferPointer) -> Int {
    Log.app.log("\(#function): \(into.count) bytes")

    return 0
  }

  func read(into: UnsafeMutableRawBufferPointer, atOffset: Int64) -> Int {
    Log.app.log("\(#function): \(into.count) bytes at offset: \(atOffset)")

    return 0
  }

  func write(from: UnsafeRawBufferPointer) -> Int {
    Log.app.log("\(#function): \(from) bytes")

    return 0
  }

  func write(from: UnsafeRawBufferPointer, atOffset: Int64) -> Int {
    Log.app.log("\(#function): \(from.count) bytes at offset: \(atOffset)")

    return 0
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
