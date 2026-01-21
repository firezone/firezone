//
//  ProviderMessage.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//
//  Encodes / Decodes messages to the provider service.

import Foundation

public enum ProviderMessage: Codable {
  case getState(Data)
  case setConfiguration(TunnelConfiguration)
  case signOut
  case clearLogs
  case getLogFolderSize
  case exportLogs

  enum CodingKeys: String, CodingKey {
    case type
    case value
  }

  enum MessageType: String, Codable {
    case getState
    case setConfiguration
    case signOut
    case clearLogs
    case getLogFolderSize
    case exportLogs
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(MessageType.self, forKey: .type)
    switch type {
    case .getState:
      let value = try container.decode(Data.self, forKey: .value)
      self = .getState(value)
    case .setConfiguration:
      let value = try container.decode(TunnelConfiguration.self, forKey: .value)
      self = .setConfiguration(value)
    case .signOut:
      self = .signOut
    case .clearLogs:
      self = .clearLogs
    case .getLogFolderSize:
      self = .getLogFolderSize
    case .exportLogs:
      self = .exportLogs
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .getState(let value):
      try container.encode(MessageType.getState, forKey: .type)
      try container.encode(value, forKey: .value)
    case .setConfiguration(let value):
      try container.encode(MessageType.setConfiguration, forKey: .type)
      try container.encode(value, forKey: .value)
    case .signOut:
      try container.encode(MessageType.signOut, forKey: .type)
    case .clearLogs:
      try container.encode(MessageType.clearLogs, forKey: .type)
    case .getLogFolderSize:
      try container.encode(MessageType.getLogFolderSize, forKey: .type)
    case .exportLogs:
      try container.encode(MessageType.exportLogs, forKey: .type)
    }
  }
}
