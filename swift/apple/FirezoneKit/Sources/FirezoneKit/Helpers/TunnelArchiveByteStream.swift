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
/// channel. Instead, we implement a custom ArchiveByteStreamProtocol to read the tunnel's log directory as
/// usual, but instead of writing to an archive file we write a bounded memory buffer.
///
/// Since the IPC channel is unidirectional from app -> tunnel, we use a simple data format to pass chunks
/// of this memory buffer from the tunnel back to the app, including a boolean `done` to indicate when the
/// app should stop reading from this buffer. The buffer is flushed when it reaches a configurable limit.
///
/// Currently this limit is set to 1 MB (chosen somewhat arbitrarily based on limited information found on the
/// web), but can be easily enlarged in the future to reduce the number of IPC calls required to consume
/// the entire archive. The LZFSE compression algorithm used by default in the Apple Archive Framework is
/// quite efficient -- compression ratios for our logs can be as high as 100:1 using this format.
///
/// To prevent the tunnel from writing to this buffer faster than the app can consume it, we implement a basic
/// backpressure mechanism that sleeps the tunnel's log export thread if the buffer is full until the app makes
/// another IPC call to wake it up. The buffer is "flushed" either when the data is fully consumed (i.e. `close()` is
/// called) or when the buffer size limit is hit. Only then will the app's completionHandler callback be called.
public class TunnelArchiveByteStream: ArchiveByteStreamProtocol {
  struct Chunk: Codable {
    var done: Bool = false
    var data = Data()
  }

  let chunkSize = 1024 * 1024 // 1 MB
  let encoder = PropertyListEncoder()
  var chunk: Chunk
  var chunkHandler: ((Data?) -> Void)?
  var logger: Log
  var completionHandler: () -> Void

  public init(
    logger: Log,
    chunkHandler: @escaping (Data?) -> Void,
    completionHandler: @escaping () -> Void
  ) {
    self.completionHandler = completionHandler
    self.logger = logger
    self.chunk = Chunk()
    self.chunkHandler = chunkHandler
  }

  public func read(into buffer: UnsafeMutableRawBufferPointer) -> Int {
    // Not implemented
    return 0
  }

  public func read(into buffer: UnsafeMutableRawBufferPointer, atOffset: Int64) -> Int {
    // Not implemented
    return 0
  }

  public func write(from buffer: UnsafeRawBufferPointer) -> Int {
    guard buffer.count <= chunkSize else {
      self.logger.error("\(#function): buffer size \(buffer.count) bytes is larger than chunk size \(chunkSize)")

      return 0
    }

    if self.chunk.data.count + buffer.count >= chunkSize {
      flush()
    }

    guard let baseAddress = buffer.baseAddress else {
      self.logger.error("\(#function): buffer has no base address!")

      return 0
    }

    let data = Data(bytes: baseAddress, count: buffer.count)
    self.chunk.data.append(data)

    self.logger.debug("appended \(data.count) bytes")

    return buffer.count
  }

  public func write(from buffer: UnsafeRawBufferPointer, atOffset: Int64) -> Int {
    // Not implemented; unused when writing to a memory buffer
    return 0
  }

  public func seek(toOffset: Int64, relativeTo: FileDescriptor.SeekOrigin) -> Int64 {
    // Not implemented; unused when writing to a memory buffer
    return 0
  }

  // It's unknown when the system calls this, but we implement it just in case.
  // Was never called during development / testing of this class.
  public func cancel() {
    // App will report this as an error
    self.chunkHandler?(nil)

    self.completionHandler()
  }

  // System calls this when compression is complete
  public func close() {
    self.chunk.done = true
    flush()

    self.completionHandler()
  }

  // App has woken us up to receive another chunk
  public func ready(_ chunkHandler: @escaping ((Data?) -> Void)) {
    self.chunkHandler = chunkHandler
  }

  // Queue next chunk for app to consume
  private func flush() {
    do {
      while self.chunkHandler == nil {
        // Wait until we're called again
        Thread.sleep(forTimeInterval: 0.01)
      }

      // Send to app
      let dataOut = try encoder.encode(self.chunk)
      self.chunkHandler?(dataOut)

      // Reset
      self.chunkHandler = nil
      self.chunk = Chunk()

    } catch {
      Log.tunnel.error("Error flushing chunk: \(error)")
    }
  }
}
