//
//  DisconnectReason.swift
//  (c) 2023 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
import os

enum DisconnectionReasonError: Error {
  case decodeError
  case cannotGetFileURL
}

public struct DisconnectionReason: Codable, CustomStringConvertible {
  private static let logger = Logger.make(for: DisconnectionReason.self)

  public enum Category: String, Codable {
    case disconnectRequested
    case connlibConnectFailure
    case connlibDisconnected
    case badTunnelConfiguration
    case tokenNotFound
    case networkSettingsApplyFailure
    case other

    var needsSignout: Bool {
      switch self {
      case .disconnectRequested, .networkSettingsApplyFailure, .other:
        return false
      case .connlibConnectFailure, .connlibDisconnected,
        .badTunnelConfiguration, .tokenNotFound:
        return true
      }
    }
  }

  public let category: DisconnectionReason.Category
  public let errorMessage: String
  public let date: Date

  public var description: String {
    if category.needsSignout {
      return "(\(category.rawValue) (needs signout), error: '\(errorMessage)', date: \(date))"
    } else {
      return "(\(category.rawValue), error: '\(errorMessage)', date: \(date))"
    }
  }

  public init(category: DisconnectionReason.Category, errorMessage: String) {
    self.category = category
    self.errorMessage = errorMessage
    self.date = Date()
  }

  public static func loadFromDisk() -> DisconnectionReason? {
    let fileURL = SharedAccess.disconnectReasonFileURL
    let fileManager = FileManager.default

    guard fileManager.fileExists(atPath: fileURL.path) else {
      return nil
    }

    guard let jsonData = try? Data(contentsOf: fileURL) else {
      Self.logger.error("Could not read disconnect reason from disk at: \(fileURL)")
      return nil
    }

    guard let reason = try? JSONDecoder().decode(DisconnectionReason.self, from: jsonData) else {
      Self.logger.error("Error decoding disconnect reason from disk at: \(fileURL)")
      return nil
    }

    do {
      try fileManager.removeItem(atPath: fileURL.path)
    } catch {
      Self.logger.error("Cannot remove disconnection reason file at \(fileURL.path)")
    }

    return reason
  }

  public static func saveToDisk(category: DisconnectionReason.Category, errorMessage: String) {
    let fileURL = SharedAccess.disconnectReasonFileURL
    Self.logger.error("Saving disconnect reason to \(fileURL, privacy: .public)")
    let disconnectReason = DisconnectionReason(
      category: category,
      errorMessage: errorMessage)
    do {
      try JSONEncoder().encode(disconnectReason).write(to: fileURL)
    } catch {
      Self.logger.error(
        "Error writing disconnect reason to disk to: \(fileURL, privacy: .public): \(error, privacy: .public)"
      )
    }
  }
}
