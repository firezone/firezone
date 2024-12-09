//
//  Log.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
import OSLog

public final class Log {
  public static let app = Log(category: .app, folderURL: SharedAccess.appLogFolderURL)
  public static let tunnel = Log(category: .tunnel, folderURL: SharedAccess.tunnelLogFolderURL)

  public enum Category: String, Codable {
    case app = "app"
    case tunnel = "tunnel"
  }

  private let logger: Logger
  private let logWriter: LogWriter?

  public init(category: Category, folderURL: URL?) {
    self.logger = Logger(subsystem: "dev.firezone.firezone", category: category.rawValue)
    self.logWriter = LogWriter(category: category, folderURL: folderURL, logger: self.logger)
  }

  public func log(_ message: String) {
    debug(message)
  }

  public func trace(_ message: String) {
    logger.trace("\(message, privacy: .public)")
    logWriter?.write(severity: .trace, message: message)
  }

  public func debug(_ message: String) {
    self.logger.debug("\(message, privacy: .public)")
    logWriter?.write(severity: .debug, message: message)
  }

  public func info(_ message: String) {
    logger.info("\(message, privacy: .public)")
    logWriter?.write(severity: .info, message: message)
  }

  public func warning(_ message: String) {
    logger.warning("\(message, privacy: .public)")
    logWriter?.write(severity: .warning, message: message)
  }

  public func error(_ message: String) {
    self.logger.error("\(message, privacy: .public)")
    logWriter?.write(severity: .error, message: message)
  }

  public static func size(of directory: URL) -> Int64 {
    let fileManager = FileManager.default
    var totalSize: Int64 = 0

    func sizeOfFile(at url: URL, with resourceValues: URLResourceValues) -> Int64 {
      guard resourceValues.isRegularFile == true else { return 0 }
      return Int64(resourceValues.totalFileAllocatedSize ?? resourceValues.totalFileSize ?? 0)
    }

    fileManager.forEachFileUnder(
      directory,
      including: [
        .totalFileAllocatedSizeKey,
        .totalFileSizeKey,
        .isRegularFileKey,
      ]
    ) { url, resourceValues in
      totalSize += sizeOfFile(at: url, with: resourceValues)
    }

    // Could take a while; bail out if we were cancelled
    guard !Task.isCancelled else {
      return 0
    }

    return totalSize
  }

  public static func clear(in directory: URL) {
    // TODO
  }
}

private final class LogWriter {
  enum Severity: String, Codable {
    case trace = "TRACE"
    case debug = "DEBUG"
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
  }

  struct LogEntry: Codable {
    let time: String
    let category: Log.Category
    let severity: Severity
    let message: String
  }

  // All log writes happen in the workQueue
  private let workQueue: DispatchQueue
  private let category: Log.Category
  private let logger: Logger
  private let handle: FileHandle
  private let dateFormatter: ISO8601DateFormatter
  private let jsonEncoder: JSONEncoder

  init?(category: Log.Category, folderURL: URL?, logger: Logger) {
    let fileManager = FileManager.default
    let dateFormatter = ISO8601DateFormatter()
    let jsonEncoder = JSONEncoder()
    dateFormatter.formatOptions = [.withFullDate, .withFullTime, .withFractionalSeconds]
    jsonEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

    self.dateFormatter = dateFormatter
    self.jsonEncoder = jsonEncoder
    self.logger = logger
    self.category = category

    // Create log dir if not exists
    guard let folderURL = folderURL,
          SharedAccess.ensureDirectoryExists(at: folderURL.path)
    else {
      logger.error("Log directory isn't acceptable!")
      return nil
    }

    let logFileURL = folderURL
      .appendingPathComponent(dateFormatter.string(from: Date()))
      .appendingPathExtension("jsonl")

    // Create log file
    guard fileManager.createFile(atPath: logFileURL.path, contents: "".data(using: .utf8)),
          let handle = try? FileHandle(forWritingTo: logFileURL),
          let _ = try? handle.seekToEnd()
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

  func write(severity: Severity, message: String) {
    let logEntry = LogEntry(
      time: dateFormatter.string(from: Date()),
      category: category,
      severity: severity,
      message: message)

    guard var jsonData = try? jsonEncoder.encode(logEntry),
          let newLineData = "\n".data(using: .utf8)
        else {
      logger.error("Could not encode log message to JSON!")
      return
    }

    jsonData.append(newLineData)

    workQueue.async { self.handle.write(jsonData) }
  }
}
