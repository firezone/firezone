//
//  Log.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
import OSLog

public final class Log {
  private static let logger: Logger = {
    switch Bundle.main.bundleIdentifier {
    case "dev.firezone.firezone":
      return Logger(subsystem: "dev.firezone.firezone", category: "app")
    case "dev.firezone.firezone.network-extension":
      return Logger(subsystem: "dev.firezone.firezone", category: "tunnel")
    default:
      // Test environment or unknown bundle - use generic logger
      let bundleId = Bundle.main.bundleIdentifier ?? "nil"
      Logger(subsystem: "dev.firezone.firezone", category: "unknown")
        .warning("Unknown bundle identifier: \(bundleId). Logging will be disabled.")
      return Logger(subsystem: "dev.firezone.firezone", category: "unknown")
    }
  }()

  private static let logWriter: LogWriter? = {
    let folderURL: URL?
    switch Bundle.main.bundleIdentifier {
    case "dev.firezone.firezone":
      folderURL = SharedAccess.appLogFolderURL
    case "dev.firezone.firezone.network-extension":
      folderURL = SharedAccess.tunnelLogFolderURL
    default:
      // Test environment or unknown bundle - no file logging
      folderURL = nil
    }
    return LogWriter(folderURL: folderURL, logger: logger)
  }()

  public static func log(_ message: String) {
    debug(message)
  }

  public static func trace(_ message: String) {
    logger.trace("\(message, privacy: .public)")
    logWriter?.write(severity: .trace, message: message)
  }

  public static func debug(_ message: String) {
    self.logger.debug("\(message, privacy: .public)")
    logWriter?.write(severity: .debug, message: message)
  }

  public static func info(_ message: String) {
    logger.info("\(message, privacy: .public)")
    logWriter?.write(severity: .info, message: message)
  }

  public static func warning(_ message: String) {
    logger.warning("\(message, privacy: .public)")
    logWriter?.write(severity: .warning, message: message)
  }

  public static func error(_ err: Error) {
    self.logger.error("\(err.localizedDescription, privacy: .public)")
    logWriter?.write(severity: .error, message: err.localizedDescription)

    if shouldCaptureError(err) {
      Telemetry.capture(err)
    }
  }

  // Returns the size in bytes of the provided directory, calculated by summing
  // the size of its contents recursively.
  public static func size(of directory: URL) async -> Int64 {
    let fileManager = FileManager.default
    var totalSize: Int64 = 0

    // Tally size of each log file in parallel
    await withTaskGroup(of: Int64.self) { taskGroup in
      fileManager.forEachFileUnder(
        directory,
        including: [
          .totalFileAllocatedSizeKey,
          .totalFileSizeKey,
          .isRegularFileKey,
        ]
      ) { _, resourceValues in
        // Extract non-Sendable values before passing to @Sendable closure
        guard resourceValues.isRegularFile == true else { return }
        let size = Int64(resourceValues.totalFileAllocatedSize ?? resourceValues.totalFileSize ?? 0)

        taskGroup.addTask { @Sendable in
          return size
        }
      }

      for await size in taskGroup {
        totalSize += size
      }
    }

    return totalSize
  }

  // Clears the contents of the provided directory.
  public static func clear(in directory: URL?) throws {
    guard let directory = directory
    else { return }

    try FileManager.default.removeItem(at: directory)
  }

  // Don't capture certain kinds of IPC and security errors in DEBUG builds
  // because these happen often due to code signing requirements.
  private static func shouldCaptureError(_ err: Error) -> Bool {
    #if DEBUG
      if let err = err as? IPCClient.Error,
        case IPCClient.Error.noIPCData = err
      {
        return false
      }
    #endif

    return true
  }
}

/// Thread-safe: All mutable state access is serialised through workQueue.
/// Log writes are queued asynchronously to avoid blocking the caller.
private final class LogWriter: @unchecked Sendable {
  enum Severity: String, Codable {
    case trace = "TRACE"
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
  }

  struct LogEntry: Codable {
    let time: String
    let severity: Severity
    let message: String
  }

  // All log writes happen in the workQueue
  private let workQueue: DispatchQueue
  private let logger: Logger
  private var handle: FileHandle
  private let dateFormatter: ISO8601DateFormatter
  private let jsonEncoder: JSONEncoder
  private let folderURL: URL  // Add this to store folder URL
  private var currentLogFileURL: URL  // Add this to track current file

  init?(folderURL: URL?, logger: Logger) {
    let fileManager = FileManager.default
    let dateFormatter = ISO8601DateFormatter()
    let jsonEncoder = JSONEncoder()
    dateFormatter.formatOptions = [.withFullDate, .withFullTime, .withFractionalSeconds]
    jsonEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

    self.dateFormatter = dateFormatter
    self.jsonEncoder = jsonEncoder
    self.logger = logger

    // Create log dir if not exists
    guard let folderURL = folderURL,
      SharedAccess.ensureDirectoryExists(at: folderURL.path)
    else {
      logger.error("Log directory isn't acceptable!")
      return nil
    }

    self.folderURL = folderURL  // Store folder URL

    let logFileURL =
      folderURL
      .appendingPathComponent(dateFormatter.string(from: Date()))
      .appendingPathExtension("jsonl")

    self.currentLogFileURL = logFileURL  // Store current file URL

    // Create log file
    guard fileManager.createFile(atPath: logFileURL.path, contents: Data()),
      let handle = try? FileHandle(forWritingTo: logFileURL),
      (try? handle.seekToEnd()) != nil
    else {
      logger.error("Could not create log file: \(logFileURL.path)")
      return nil
    }

    self.handle = handle
    self.workQueue = DispatchQueue(label: "LogWriter.workQueue", qos: .utility)
  }

  deinit {
    do {
      try self.handle.close()
    } catch {
      logger.error("Could not close logfile: \(error)")
    }
  }

  // Returns a valid file handle, recreating file if necessary
  private func ensureFileExists() -> FileHandle? {
    let fileManager = FileManager.default

    // Check if current file still exists
    if fileManager.fileExists(atPath: currentLogFileURL.path) {
      return handle
    }

    // File was deleted, need to recreate
    try? handle.close()

    // Ensure directory exists
    guard SharedAccess.ensureDirectoryExists(at: folderURL.path) else {
      logger.error("Could not recreate log directory")
      return nil
    }

    // Create new log file
    guard fileManager.createFile(atPath: currentLogFileURL.path, contents: Data()),
      let newHandle = try? FileHandle(forWritingTo: currentLogFileURL),
      (try? newHandle.seekToEnd()) != nil
    else {
      logger.error("Could not recreate log file: \(self.currentLogFileURL.path)")
      return nil
    }

    self.handle = newHandle
    return newHandle
  }

  func write(severity: Severity, message: String) {
    let logEntry = LogEntry(
      time: dateFormatter.string(from: Date()),
      severity: severity,
      message: message)

    guard let jsonData = try? jsonEncoder.encode(logEntry) + Data("\n".utf8)
    else {
      logger.error("Could not encode log message to JSON!")
      return
    }

    workQueue.async { [weak self] in
      guard let self = self else { return }
      guard let handle = self.ensureFileExists() else { return }

      handle.write(jsonData)
    }
  }
}
