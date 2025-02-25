//
//  ProviderMessage.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//
//  Encodes / Decodes messages to the provider service.

import Foundation

public enum ProviderMessage: Codable {
  case getResourceList(Data)
  case signOut
  case internetResourceEnabled(Bool)
  case clearLogs
  case getLogFolderSize
  case exportLogs
  case consumeStopReason

  enum CodingKeys: String, CodingKey {
    case type
    case value
  }

  enum MessageType: String, Codable {
    case getResourceList
    case signOut
    case internetResourceEnabled
    case clearLogs
    case getLogFolderSize
    case exportLogs
    case consumeStopReason
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(MessageType.self, forKey: .type)
    switch type {
    case .internetResourceEnabled:
      let value = try container.decode(Bool.self, forKey: .value)
      self = .internetResourceEnabled(value)
    case .getResourceList:
      let value = try container.decode(Data.self, forKey: .value)
      self = .getResourceList(value)
    case .signOut:
      self = .signOut
    case .clearLogs:
      self = .clearLogs
    case .getLogFolderSize:
      self = .getLogFolderSize
    case .exportLogs:
      self = .exportLogs
    case .consumeStopReason:
      self = .consumeStopReason
    }
  }
  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .internetResourceEnabled(let value):
      try container.encode(MessageType.internetResourceEnabled, forKey: .type)
      try container.encode(value, forKey: .value)
    case .getResourceList(let value):
      try container.encode(MessageType.getResourceList, forKey: .type)
      try container.encode(value, forKey: .value)
    case .signOut:
      try container.encode(MessageType.signOut, forKey: .type)
    case .clearLogs:
      try container.encode(MessageType.clearLogs, forKey: .type)
    case .getLogFolderSize:
      try container.encode(MessageType.getLogFolderSize, forKey: .type)
    case .exportLogs:
      try container.encode(MessageType.exportLogs, forKey: .type)
    case .consumeStopReason:
      try container.encode(MessageType.consumeStopReason, forKey: .type)
    }
  }
}
