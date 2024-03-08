//
//  DisconnectReason.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
import NetworkExtension
import os

enum TunnelShutdownEventError: Error {
  case decodeError
  case cannotGetFileURL
}

public struct TunnelShutdownEvent: Codable, CustomStringConvertible {
  public enum Reason: Codable, CustomStringConvertible {
    case stopped(NEProviderStopReason)
    case connlibConnectFailure
    case connlibDisconnected
    case badTunnelConfiguration
    case tokenNotFound
    case networkSettingsApplyFailure
    case invalidAdapterState

    public var description: String {
      switch self {
      case .stopped(let reason): return "stopped(reason code: \(reason.rawValue))"
      case .connlibConnectFailure: return "connlib connection failure"
      case .connlibDisconnected: return "connlib disconnected"
      case .badTunnelConfiguration: return "bad tunnel configuration"
      case .tokenNotFound: return "token not found"
      case .networkSettingsApplyFailure: return "network settings apply failure"
      case .invalidAdapterState: return "invalid adapter state"
      }
    }

    public var action: Action {
      switch self {
      case .stopped(let reason):
        if reason == .userInitiated {
          return .signoutImmediatelySilently
        } else if reason == .userLogout || reason == .userSwitch {
          return .doNothing
        } else {
          return .retryThenSignout
        }
      case .networkSettingsApplyFailure, .invalidAdapterState:
        return .retryThenSignout
      case .connlibConnectFailure, .connlibDisconnected,
        .badTunnelConfiguration, .tokenNotFound:
        return .signoutImmediately
      }
    }
  }

  public enum Action {
    case doNothing
    case signoutImmediately
    case signoutImmediatelySilently
    case retryThenSignout
  }

  public let reason: TunnelShutdownEvent.Reason
  public let errorMessage: String
  public let date: Date

  public var action: Action { reason.action }

  public var description: String {
    "(\(reason)\(action == .signoutImmediately ? " (needs immediate signout)" : ""), error: '\(errorMessage)', date: \(date))"
  }

  public init(reason: TunnelShutdownEvent.Reason, errorMessage: String) {
    self.reason = reason
    self.errorMessage = errorMessage
    self.date = Date()
  }

  public static func loadFromDisk(logger: AppLogger) -> TunnelShutdownEvent? {
    let fileURL = SharedAccess.tunnelShutdownEventFileURL
    let fileManager = FileManager.default

    guard fileManager.fileExists(atPath: fileURL.path) else {
      return nil
    }

    guard let jsonData = try? Data(contentsOf: fileURL) else {
      logger.error("Could not read tunnel shutdown event from disk at: \(fileURL)")
      return nil
    }

    guard let reason = try? JSONDecoder().decode(TunnelShutdownEvent.self, from: jsonData) else {
      logger.error("Error decoding tunnel shutdown event from disk at: \(fileURL)")
      return nil
    }

    do {
      try fileManager.removeItem(atPath: fileURL.path)
    } catch {
      logger.error("Cannot remove tunnel shutdown event file at \(fileURL.path)")
    }

    return reason
  }

  public static func saveToDisk(
    reason: TunnelShutdownEvent.Reason, errorMessage: String, logger: AppLogger
  ) {
    let fileURL = SharedAccess.tunnelShutdownEventFileURL
    logger.error("Saving tunnel shutdown event data to \(fileURL)")
    let tsEvent = TunnelShutdownEvent(
      reason: reason,
      errorMessage: errorMessage)
    do {
      try JSONEncoder().encode(tsEvent).write(to: fileURL)
    } catch {
      logger.error(
        "Error writing tunnel shutdown event data to disk to: \(fileURL): \(error)"
      )
    }
  }
}

extension NEProviderStopReason: Codable {
}
