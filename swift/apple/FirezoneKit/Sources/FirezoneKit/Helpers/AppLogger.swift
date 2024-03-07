//
//  AppLogger.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Dependencies
import Foundation
import OSLog

public final class AppLogger {
  public enum Process: String {
    case app
    case tunnel
  }

  private let logger: Logger
  private let folderURL: URL?
  private let logWriter: LogWriter?
  private let dateFormatter: DateFormatter

  public init(process: Process, folderURL: URL?) {
    let logger = Logger(subsystem: "dev.firezone.firezone", category: process.rawValue)
    if folderURL == nil {
      logger.log("AppLogger.init: folderURL is nil")
    }
    self.logger = logger
    self.folderURL = folderURL
    let target = LogWriter.Target(process: process)
    self.logWriter = LogWriter(target: target, folderURL: folderURL, logger: self.logger)

    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS Z"
    self.dateFormatter = dateFormatter

    log("Starting logging")

    let appVersionString = Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? "Unknown"
    log("Firezone \(appVersionString) (\(process.rawValue) process)")

    let osVersionString = ProcessInfo.processInfo.operatingSystemVersionString
    #if os(iOS)
      log("iOS \(osVersionString)")
    #elseif os(macOS)
      log("macOS \(osVersionString)")
    #endif
  }

  public func log(_ message: String) {
    self.logger.log("\(message, privacy: .public)")
    logWriter?.writeLogEntry(severity: .debug, message: message)
  }

  public func error(_ message: String) {
    self.logger.error("\(message, privacy: .public)")
    logWriter?.writeLogEntry(severity: .error, message: message)
  }
}

private final class LogWriter {
  struct DiskLog {
    let logIndex: Int
    let filePointer: UnsafeMutablePointer<FILE>
    let fileSizeAtOpen: UInt64
  }

  class MemoryLog {
    var data = Data()

    func reset() {
      self.data = Data()
    }
  }

  enum Severity: String, Codable {
    case debug = "DEBUG"
    case error = "ERROR"
  }

  struct LogEntry: Codable {
    let time: String
    let target: Target
    let severity: Severity
    let message: String
  }

  private enum LogDestination {
    // Normally, write log entries to disk
    case disk(DiskLog?)
    // While setting up the disk log, or when switching to
    // a different log file, write to memory temporarily,
    // so that it can be later written to disk
    case memory(MemoryLog)
  }

  enum Target: String, Codable {
    case appMacOS = "app_macos"
    case appiOS = "app_ios"
    case tunnelMacOS = "tunnel_macos"
    case tunneliOS = "tunnel_ios"

    init(process: AppLogger.Process) {
      #if os(iOS)
        switch process {
        case .app: self = .appiOS
        case .tunnel: self = .tunneliOS
        }
      #elseif os(macOS)
        switch process {
        case .app: self = .appMacOS
        case .tunnel: self = .tunnelMacOS
        }
      #endif
    }
  }

  private let target: Target
  private let folderURL: URL
  private let logger: Logger

  // All log writes happen in the workQueue
  private let workQueue: DispatchQueue

  // Switching between log files happen in the diskLogSwitchingQueue
  private let diskLogSwitchingQueue: DispatchQueue

  private var logDestination: LogDestination
  private var fileSizeAddendum: UInt64 = 0
  private let dateFormatter: ISO8601DateFormatter
  private let jsonEncoder: JSONEncoder
  private let newlineData: Data

  private let logFileNameBase: String
  private let currentIndexFileURL: URL

  private static let logFileNameExtension = "log"
  private static let currentIndexFileName = "firezone_log_current_index"
  private static let maxLogFileSize = 1024 * 1024 * 1024  // 1 MB
  private static let maxLogFilesCount = 5

  init?(target: Target, folderURL: URL?, logger: Logger) {
    guard let folderURL = folderURL else {
      logger.error("LogWriter.init: folderURL is nil")
      return nil
    }

    self.target = target
    self.folderURL = folderURL
    self.logger = logger
    self.logFileNameBase = target.rawValue
    self.currentIndexFileURL = self.folderURL.appendingPathComponent(Self.currentIndexFileName)

    let dateFormatter = ISO8601DateFormatter()
    dateFormatter.formatOptions = [.withFullDate, .withFullTime, .withFractionalSeconds]
    self.dateFormatter = dateFormatter

    let jsonEncoder = JSONEncoder()
    jsonEncoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    self.jsonEncoder = jsonEncoder

    self.newlineData = "\n".data(using: .utf8)!

    workQueue = DispatchQueue(label: "LogWriter.workQueue", qos: .utility)
    diskLogSwitchingQueue = DispatchQueue(
      label: "LogWriter.diskLogSwitchingQueue", qos: .background)

    self.logger.error("LogWriter.init: Temporarily using memory log")
    logDestination = .memory(MemoryLog())

    performInitialSetup()
  }

  private func performInitialSetup() {
    diskLogSwitchingQueue.async {
      let currentIndex: Int = {
        let currentIndexFromFile: Int? = {
          guard let currentIndexString = try? String(contentsOf: self.currentIndexFileURL) else {
            return nil
          }
          return Int(currentIndexString)
        }()
        if let currentIndexFromFile = currentIndexFromFile {
          self.logger.error(
            "LogWriter.performInitialSetup: Current log index read from file: \(currentIndexFromFile, privacy: .public)"
          )
          return currentIndexFromFile
        } else {
          self.logger.error(
            "LogWriter.performInitialSetup: Current log index could not be read from file. Assuming current log index as 0."
          )
          try? "0".write(to: self.currentIndexFileURL, atomically: true, encoding: .utf8)
          return 0
        }
      }()

      let diskLog = Self.openDiskLog(
        folderURL: self.folderURL, logFileNameBase: self.logFileNameBase,
        logIndex: currentIndex, shouldRemoveExistingFile: false,
        logger: self.logger
      )

      if diskLog == nil {
        self.logger.error(
          "LogWriter.performInitialSetup: Unable to switch log. Log entries will not be written to disk."
        )
      }

      self.workQueue.async {
        if case .memory(let memoryLog) = self.logDestination {
          let bytesWritten =
            Self.writeMemoryLogToDisk(memoryLog: memoryLog, diskLog: diskLog, logger: self.logger)
          self.fileSizeAddendum = UInt64(bytesWritten)
          self.logDestination = .disk(diskLog)
          self.logger.error(
            "LogWriter.performInitialSetup: Switched to disk log."
          )
        }
      }
    }
  }

  private static func openDiskLog(
    folderURL: URL, logFileNameBase: String,
    logIndex: Int, shouldRemoveExistingFile: Bool, logger: Logger
  ) -> DiskLog? {

    let fileManager = FileManager.default

    // Look for an existing log file with this log index
    var existingLogFiles: [URL] = []
    if let enumerator = fileManager.enumerator(
      at: folderURL,
      includingPropertiesForKeys: [.isRegularFileKey, .nameKey],
      options: [.skipsHiddenFiles, .skipsPackageDescendants, .skipsSubdirectoryDescendants],
      errorHandler: nil
    ) {
      for item in enumerator.enumerated() {
        guard let url = item.element as? URL else { continue }
        do {
          let resourceValues = try url.resourceValues(forKeys: [.isRegularFileKey, .nameKey])
          if resourceValues.isRegularFile ?? false {
            if let fileName = resourceValues.name {
              if fileName.hasPrefix("\(logFileNameBase).")
                && fileName.hasSuffix(".\(logIndex).\(Self.logFileNameExtension)")
              {
                existingLogFiles.append(url)
              }
            }
          }
        } catch {
          logger.error(
            "LogWriter.openDiskLog: Unable to get resource value for '\(url.path, privacy: .public)': \(error, privacy: .public)"
          )
        }
      }
    }

    if !shouldRemoveExistingFile && existingLogFiles.count > 0 {
      // Open the existing log file in append mode
      if existingLogFiles.count > 1 {
        // In case there are multiple log files at this index (there shouldn't be),
        // pick something predictably, so we pick the same one each time.
        existingLogFiles.sort(by: { $0.lastPathComponent > $1.lastPathComponent })
      }

      let existingLogFile = existingLogFiles.first!
      let existingLogFilePath = existingLogFile.path

      logger.error(
        "LogWriter.openDiskLog: File exists at '\(existingLogFilePath, privacy: .public)'"
      )
      var fileSize: UInt64? = nil
      do {
        let attr = try fileManager.attributesOfItem(atPath: existingLogFilePath)
        fileSize = attr[FileAttributeKey.size] as? UInt64
      } catch {
        logger.error(
          "LogWriter.openDiskLog: Error getting file attributes of '\(existingLogFilePath, privacy: .public)': \(error, privacy: .public)"
        )
        return nil
      }
      if let fileSize = fileSize {
        if let filePointer = fopen(existingLogFilePath, "a") {
          return DiskLog(logIndex: logIndex, filePointer: filePointer, fileSizeAtOpen: fileSize)
        } else {
          logger.error(
            "LogWriter.openDiskLog: Can't open file '\(existingLogFilePath, privacy: .public)' for appending"
          )
          return nil
        }
      } else {
        logger.error(
          "LogWriter.openDiskLog: Can't figure out file size for '\(existingLogFilePath, privacy: .public)'"
        )
        return nil
      }
    }

    if shouldRemoveExistingFile {
      // Remove the existing log file
      for existingLogFile in existingLogFiles {
        // In case there are multiple log files at this index (there shouldn't be),
        // remove all of them.
        do {
          logger.error(
            "LogWriter.openDiskLog: Removing file at '\(existingLogFile.path, privacy: .public)'"
          )
          try fileManager.removeItem(at: existingLogFile)
        } catch {
          logger.error(
            "LogWriter.openDiskLog: Error removing file '\(existingLogFile.path, privacy: .public)'"
          )
        }
      }
    }

    // There's no log file at this log index. Create a new log file in write mode.
    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd-HH-mm-ss"
    let timestamp = dateFormatter.string(from: Date())
    let logFileURL = folderURL.appendingPathComponent(
      "\(logFileNameBase).\(timestamp).\(logIndex).\(Self.logFileNameExtension)")
    let logFilePath = logFileURL.path
    logger.error("LogWriter.openDiskLog: Creating file at '\(logFilePath, privacy: .public)'")
    if let filePointer = fopen(logFilePath, "w") {
      return DiskLog(logIndex: logIndex, filePointer: filePointer, fileSizeAtOpen: 0)
    } else {
      logger.error(
        "LogWriter.openDiskLog: Can't open file '\(logFilePath, privacy: .public)' for writing"
      )
      return nil
    }
  }

  func writeLogEntry(severity: Severity, message: String) {
    let logEntry = LogEntry(
      time: self.dateFormatter.string(from: Date()),
      target: self.target,
      severity: severity,
      message: message)
    var jsonData = Data()
    do {
      jsonData = try jsonEncoder.encode(logEntry)
      jsonData.append(self.newlineData)
    } catch {
      self.logger.error(
        "LogWriter.writeLogEntry: Error encoding log entry to JSON: \(error, privacy: .public)"
      )
    }

    workQueue.async {
      switch self.logDestination {
      case .disk(let diskLogNullable):
        guard let diskLog = diskLogNullable else { return }
        var bytesWritten = 0
        do {
          bytesWritten = try Self.writeDataToDisk(data: jsonData, diskLog: diskLog)
        } catch {
          self.logger.error(
            "LogWriter.writeLogEntry: Error writing log entry to disk: \(error, privacy: .public)"
          )
        }
        self.fileSizeAddendum += UInt64(bytesWritten)

        if (diskLog.fileSizeAtOpen + self.fileSizeAddendum) > Self.maxLogFileSize {
          let memoryLog = MemoryLog()
          self.logDestination = .memory(memoryLog)
          self.fileSizeAddendum = 0
          self.logger.error("LogWriter.writeLogEntry: Temporarily using memory log")

          self.diskLogSwitchingQueue.async {
            fclose(diskLog.filePointer)
            let nextLogIndex = (diskLog.logIndex + 1) % Self.maxLogFilesCount
            let nextDiskLogNullable = Self.openDiskLog(
              folderURL: self.folderURL, logFileNameBase: self.logFileNameBase,
              logIndex: nextLogIndex,
              shouldRemoveExistingFile: true, logger: self.logger
            )

            guard let nextDiskLog = nextDiskLogNullable else {
              self.logger.error(
                "LogWriter.writeLogEntry: Unable to switch log. Log entries will not be written to disk."
              )
              self.workQueue.async {
                self.logDestination = .disk(nil)
              }
              return
            }

            do {
              try "\(nextLogIndex)"
                .write(to: self.currentIndexFileURL, atomically: true, encoding: .utf8)
            } catch {
              self.logger.error(
                "LogWriter.writeLogEntry: Error writing current index as '\(nextLogIndex)' to disk: \(error, privacy: .public)"
              )
              return
            }

            self.workQueue.async {
              let bytesWritten = Self.writeMemoryLogToDisk(
                memoryLog: memoryLog, diskLog: nextDiskLog, logger: self.logger)
              self.fileSizeAddendum = UInt64(bytesWritten)
              self.logDestination = .disk(nextDiskLog)
              self.logger.error("LogWriter.writeLogEntry: Switched to disk log")
            }
          }
        }
      case .memory(let memoryLog):
        memoryLog.data.append(jsonData)
      }
    }
  }

  private static func writeMemoryLogToDisk(memoryLog: MemoryLog, diskLog: DiskLog?, logger: Logger)
    -> Int
  {
    guard let diskLog = diskLog else {
      logger.error("LogWriter.writeMemoryLogToDisk: diskLog is nil")
      return 0
    }

    guard memoryLog.data.count > 0 else {
      return 0
    }

    do {
      logger.log(
        "LogWriter.writeMemoryLogToDisk: Writing memory log to disk (\(memoryLog.data.count, privacy: .public) bytes)"
      )
      return try writeDataToDisk(data: memoryLog.data, diskLog: diskLog)
    } catch {
      logger.error(
        "LogWriter.writeMemoryLogToDisk: Error writing memory log to disk: \(error, privacy: .public)"
      )
    }

    return 0
  }

  private static func writeDataToDisk(data: Data, diskLog: DiskLog) throws -> Int {
    var bytesWritten = 0
    if data.count > 0 {
      bytesWritten = try data.withUnsafeBytes<Int> { pointer -> Int in
        fwrite(
          pointer.baseAddress, MemoryLayout<CChar>.size, data.count,
          diskLog.filePointer
        )
      }
      fflush(diskLog.filePointer)
    }
    return bytesWritten
  }
}
