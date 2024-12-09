//
//  TunnelMessage.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//
//  Facilitates encoding and decoding IPC messages to the Provider.

import Foundation

public enum TunnelMessage: Codable {
  case getResourceList(Data)
  case signOut
  case internetResourceEnabled(Bool)
  case getLogFolderURL
  case clearLogs

  enum CodingKeys: String, CodingKey {
    case type
    case value
  }

  enum MessageType: String, Codable {
    case getResourceList
    case signOut
    case internetResourceEnabled
    case getLogDirHandle
    case clearLogs
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
    case .getLogDirHandle:
      self = .getLogFolderURL
    case .clearLogs:
      self = .clearLogs
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
    case .getLogFolderURL:
      try container.encode(MessageType.getLogDirHandle, forKey: .type)
    case .clearLogs:
      try container.encode(MessageType.clearLogs, forKey: .type)
    }
  }
}
