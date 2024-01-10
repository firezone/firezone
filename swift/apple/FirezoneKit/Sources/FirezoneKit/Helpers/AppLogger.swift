//
//  AppLogger.swift
//  (c) 2023 Firezone, Inc.
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
    self.logWriter = LogWriter(process: process, folderURL: folderURL, logger: self.logger)

    let dateFormatter = DateFormatter()
    dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS Z"
    self.dateFormatter = dateFormatter
  }

  public func log(_ message: String) {
    self.logger.log("\(message, privacy: .public)")
    logWriter?.writeLogEntry("\(dateFormatter.string(from: Date())): Debug: \(message)\n")
  }

  public func error(_ message: String) {
    self.logger.error("\(message, privacy: .public)")
    logWriter?.writeLogEntry("\(dateFormatter.string(from: Date())): Error: \(message)\n")
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

  private enum LogDestination {
    // Normally, write log entries to disk
    case disk(DiskLog?)
    // While setting up the disk log, or when switching to
    // a different log file, write to memory temporarily,
    // so that it can be later written to disk
    case memory(MemoryLog)
  }

  private let folderURL: URL
  private let logger: Logger

  // All log writes happen in the workQueue
  private let workQueue: DispatchQueue

  // Switching between log files happen in the diskLogSwitchingQueue
  private let diskLogSwitchingQueue: DispatchQueue

  private var logDestination: LogDestination
  private var fileSizeAddendum: UInt64 = 0

  private let logFileNameBase: String
  private let currentIndexFileURL: URL

  private static let logFileNameExtension = "log"
  private static let currentIndexFileName = "firezone_log_current_index"
  private static let maxLogFileSize = 1024 * 1024 * 1024  // 1 MB
  private static let maxLogFilesCount = 5

  init?(process: AppLogger.Process, folderURL: URL?, logger: Logger) {
    guard let folderURL = folderURL else {
      logger.error("LogWriter.init: folderURL is nil")
      return nil
    }

    self.folderURL = folderURL
    self.logger = logger
    self.logFileNameBase = "\(process.rawValue)."
    self.currentIndexFileURL = self.folderURL.appendingPathComponent(Self.currentIndexFileName)

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

    let logFileURL = folderURL.appendingPathComponent(
      "\(logFileNameBase)\(logIndex).\(Self.logFileNameExtension)")
    let logFilePath = logFileURL.path

    let fileManager = FileManager.default

    if shouldRemoveExistingFile {
      do {
        logger.error("LogWriter.openDiskLog: Removing file at '\(logFilePath, privacy: .public)'")
        try fileManager.removeItem(atPath: logFilePath)
      } catch {
        logger.error(
          "LogWriter.openDiskLog: Error removing file '\(logFilePath, privacy: .public)'"
        )
      }
    }

    if !shouldRemoveExistingFile && fileManager.fileExists(atPath: logFilePath) {
      logger.error("LogWriter.openDiskLog: File exists at '\(logFilePath, privacy: .public)'")
      var fileSize: UInt64? = nil
      do {
        let attr = try fileManager.attributesOfItem(atPath: logFilePath)
        fileSize = attr[FileAttributeKey.size] as? UInt64
      } catch {
        logger.error(
          "LogWriter.openDiskLog: Error getting file attributes of '\(logFilePath, privacy: .public)': \(error, privacy: .public)"
        )
        return nil
      }
      if let fileSize = fileSize {
        if let filePointer = fopen(logFilePath, "a") {
          return DiskLog(logIndex: logIndex, filePointer: filePointer, fileSizeAtOpen: fileSize)
        } else {
          logger.error(
            "LogWriter.openDiskLog: Can't open file '\(logFilePath, privacy: .public)' for appending"
          )
          return nil
        }
      } else {
        logger.error(
          "LogWriter.openDiskLog: Can't figure out file size for '\(logFilePath, privacy: .public)'"
        )
        return nil
      }
    } else {
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
  }

  func writeLogEntry(_ entry: String) {
    guard let cStr = entry.cString(using: .utf8) else { return }

    workQueue.async {
      switch self.logDestination {
      case .disk(let diskLogNullable):
        guard let diskLog = diskLogNullable else { return }
        let bytesWritten = fwrite(
          cStr, MemoryLayout<CChar>.size, cStr.count - 1, diskLog.filePointer
        )
        fflush(diskLog.filePointer)
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
        memoryLog.data.append(Data(bytes: cStr, count: cStr.count - 1))
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
    var bytesWritten = 0
    if memoryLog.data.count > 0 {
      logger.log(
        "LogWriter.writeMemoryLogToDisk: Writing memory log to disk (\(memoryLog.data.count, privacy: .public) bytes)"
      )
      do {
        bytesWritten = try memoryLog.data.withUnsafeBytes<Int> { pointer -> Int in
          fwrite(
            pointer.baseAddress, MemoryLayout<CChar>.size, memoryLog.data.count,
            diskLog.filePointer
          )
        }
      } catch {
        logger.error(
          "LogWriter.writeLogEntry: Error writing memory log to disk: \(error, privacy: .public)"
        )
      }
      fflush(diskLog.filePointer)
    }
    return bytesWritten
  }
}
