//
//  LogWriterTests.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
import OSLog
import Testing

@testable import FirezoneKit

@Suite("LogWriter Tests")
struct LogWriterTests {

  @Test("LogWriter doesn't crash when handle is closed during writes")
  func doesntCrashWhenHandleClosedDuringWrites() async throws {
    let tempDir = FileManager.default.temporaryDirectory
      .appendingPathComponent(UUID().uuidString)

    defer { try? FileManager.default.removeItem(at: tempDir) }

    let logger = Logger(subsystem: "dev.firezone.firezone", category: "test")
    guard let writer = LogWriter(folderURL: tempDir, logger: logger) else {
      Issue.record("Failed to create LogWriter")
      return
    }

    // Trigger race condition: close handle while writes are in flight
    await withTaskGroup(of: Void.self) { group in
      // Writer task: queue many writes
      group.addTask {
        for i in 0..<10000 {
          writer.write(severity: .info, message: "Message \(i)")
        }
      }

      // Closer task: grab handle via ensureFileExists and close it
      group.addTask {
        try? await Task.sleep(for: .milliseconds(5))
        if let handle = writer.ensureFileExists() {
          try? handle.close()
        }
      }
    }
  }
}
