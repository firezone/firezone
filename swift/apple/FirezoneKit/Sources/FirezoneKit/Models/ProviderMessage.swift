//
//  ProviderMessage.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//
//  Encodes / Decodes messages to the provider service.

import Foundation

public enum ProviderMessage: Codable {
  case getState(Data)
  case setInternetResourceEnabled(Bool)
  case signOut
  case clearLogs
  case getLogFolderSize
  case exportLogs
  case getEncodedFirezoneId
  case registerUploader

  enum CodingKeys: String, CodingKey {
    case type
    case value
  }

  enum MessageType: String, Codable {
    case getState
    case setInternetResourceEnabled
    case signOut
    case clearLogs
    case getLogFolderSize
    case exportLogs
    case getEncodedFirezoneId
    case registerUploader
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(MessageType.self, forKey: .type)
    switch type {
    case .getState:
      let value = try container.decode(Data.self, forKey: .value)
      self = .getState(value)
    case .setInternetResourceEnabled:
      let value = try container.decode(Bool.self, forKey: .value)
      self = .setInternetResourceEnabled(value)
    case .signOut:
      self = .signOut
    case .clearLogs:
      self = .clearLogs
    case .getLogFolderSize:
      self = .getLogFolderSize
    case .exportLogs:
      self = .exportLogs
    case .getEncodedFirezoneId:
      self = .getEncodedFirezoneId
    case .registerUploader:
      self = .registerUploader
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .getState(let value):
      try container.encode(MessageType.getState, forKey: .type)
      try container.encode(value, forKey: .value)
    case .setInternetResourceEnabled(let value):
      try container.encode(MessageType.setInternetResourceEnabled, forKey: .type)
      try container.encode(value, forKey: .value)
    case .signOut:
      try container.encode(MessageType.signOut, forKey: .type)
    case .clearLogs:
      try container.encode(MessageType.clearLogs, forKey: .type)
    case .getLogFolderSize:
      try container.encode(MessageType.getLogFolderSize, forKey: .type)
    case .exportLogs:
      try container.encode(MessageType.exportLogs, forKey: .type)
    case .getEncodedFirezoneId:
      try container.encode(MessageType.getEncodedFirezoneId, forKey: .type)
    case .registerUploader:
      try container.encode(MessageType.registerUploader, forKey: .type)
    }
  }
}
