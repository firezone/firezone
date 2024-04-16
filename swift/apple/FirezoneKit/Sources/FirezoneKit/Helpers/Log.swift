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
  private let logFileURL: URL
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
    self.logFileURL = folderURL
      .appendingPathComponent(dateFormatter.string(from: Date()))
      .appendingPathExtension("log")

    // Create log file
    guard fileManager.createFile(atPath: self.logFileURL.path, contents: "".data(using: .utf8))
    else {
      logger.error("Could not create log file: \(self.logFileURL.path)")
      return nil
    }

    self.workQueue = DispatchQueue(label: "LogWriter.workQueue", qos: .utility)
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

    workQueue.async {
      do {
        let handle = try FileHandle(forWritingTo: self.logFileURL)
        try handle.seekToEnd()
        handle.write(jsonData)
        try handle.close()
      } catch {
        self.logger.error("Could write log file \(self.logFileURL): \(error)")
      }
    }
  }
}
