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

  public init(process: Process) {
    self.logger = Logger(subsystem: "dev.firezone.firezone", category: process.rawValue)
  }

  public func log(_ message: String) {
    self.logger.log("\(message, privacy: .public)")
  }

  public func error(_ message: String) {
    self.logger.error("\(message, privacy: .public)")
  }
}
