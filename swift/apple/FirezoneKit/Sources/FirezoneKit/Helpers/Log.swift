//
//  Log.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
import OSLog

public final class Log {
  private static var logger = switch Bundle.main.bundleIdentifier {
  case "dev.firezone.firezone":
    Logger(subsystem: "dev.firezone.firezone", category: "app")
  case "dev.firezone.firezone.network-extension":
    Logger(subsystem: "dev.firezone.firezone", category: "tunnel")
  default:
    fatalError("Unknown bundle id: \(Bundle.main.bundleIdentifier!)")
  }

  private static var logWriter = switch Bundle.main.bundleIdentifier {
  case "dev.firezone.firezone":
    LogWriter(folderURL: SharedAccess.appLogFolderURL, logger: logger)
  case "dev.firezone.firezone.network-extension":
    LogWriter(folderURL: SharedAccess.tunnelLogFolderURL, logger: logger)
  default:
    fatalError("Unknown bundle id: \(Bundle.main.bundleIdentifier!)")
  }

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

    func sizeOfFile(at url: URL, with resourceValues: URLResourceValues) -> Int64 {
      guard resourceValues.isRegularFile == true else { return 0 }
      return Int64(resourceValues.totalFileAllocatedSize ?? resourceValues.totalFileSize ?? 0)
    }

    // Tally size of each log file in parallel
    await withTaskGroup(of: Int64.self) { taskGroup in
      fileManager.forEachFileUnder(
        directory,
        including: [
          .totalFileAllocatedSizeKey,
          .totalFileSizeKey,
          .isRegularFileKey,
        ]
      ) { url, resourceValues in
        taskGroup.addTask {
          return sizeOfFile(at: url, with: resourceValues)
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
    if let err = err as? VPNConfigurationManagerError,
       case VPNConfigurationManagerError.noIPCData = err {
      return false
    }
#endif

    return true
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
    let severity: Severity
    let message: String
  }

  // All log writes happen in the workQueue
  private let workQueue: DispatchQueue
  private let logger: Logger
  private let handle: FileHandle
  private let dateFormatter: ISO8601DateFormatter
  private let jsonEncoder: JSONEncoder

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
      severity: severity,
      message: message)

    guard var jsonData = try? jsonEncoder.encode(logEntry),
          let newLineData = "\n".data(using: .utf8)
        else {
      logger.error("Could not encode log message to JSON!")
      return
    }

    jsonData.append(newLineData)

    workQueue.async { [weak self] in
      self?.handle.write(jsonData)
    }
  }
}
