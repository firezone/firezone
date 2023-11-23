//
//  DisconnectReason.swift
//  (c) 2023 Firezone, Inc.
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
  private static let logger = Logger.make(for: TunnelShutdownEvent.self)

  public enum Reason: Codable {
    case stopped(NEProviderStopReason)
    case connlibConnectFailure
    case connlibDisconnected
    case badTunnelConfiguration
    case tokenNotFound
    case networkSettingsApplyFailure
    case invalidAdapterState
  }

  public enum Action {
    case signoutImmediately
    case retryThenSignout
  }

  public let reason: TunnelShutdownEvent.Reason
  public let errorMessage: String
  public let date: Date

  public var action: Action {
    switch reason {
    case .stopped(let reason):
      if reason == .userInitiated || reason == .userLogout || reason == .userSwitch {
        return .signoutImmediately
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

  public var description: String {
    "(\(reason)\(action == .signoutImmediately ? " (needs immediate signout)" : ""), error: '\(errorMessage)', date: \(date))"
  }

  public init(reason: TunnelShutdownEvent.Reason, errorMessage: String) {
    self.reason = reason
    self.errorMessage = errorMessage
    self.date = Date()
  }

  public static func loadFromDisk() -> TunnelShutdownEvent? {
    let fileURL = SharedAccess.tunnelShutdownEventFileURL
    let fileManager = FileManager.default

    guard fileManager.fileExists(atPath: fileURL.path) else {
      return nil
    }

    guard let jsonData = try? Data(contentsOf: fileURL) else {
      Self.logger.error("Could not read tunnel shutdown event from disk at: \(fileURL)")
      return nil
    }

    guard let reason = try? JSONDecoder().decode(TunnelShutdownEvent.self, from: jsonData) else {
      Self.logger.error("Error decoding tunnel shutdown event from disk at: \(fileURL)")
      return nil
    }

    do {
      try fileManager.removeItem(atPath: fileURL.path)
    } catch {
      Self.logger.error("Cannot remove tunnel shutdown event file at \(fileURL.path)")
    }

    return reason
  }

  public static func saveToDisk(reason: TunnelShutdownEvent.Reason, errorMessage: String) {
    let fileURL = SharedAccess.tunnelShutdownEventFileURL
    Self.logger.error("Saving tunnel shutdown event data to \(fileURL, privacy: .public)")
    let tsEvent = TunnelShutdownEvent(
      reason: reason,
      errorMessage: errorMessage)
    do {
      try JSONEncoder().encode(tsEvent).write(to: fileURL)
    } catch {
      Self.logger.error(
        "Error writing tunnel shutdown event data to disk to: \(fileURL, privacy: .public): \(error, privacy: .public)"
      )
    }
  }
}

extension NEProviderStopReason: Codable {
}
