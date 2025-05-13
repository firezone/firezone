//
//  ProviderMessage.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//
//  Encodes / Decodes messages to the provider service.

import Foundation

// TODO: Can we simplify this / abstract it?
// swiftlint:disable cyclomatic_complexity

public enum ProviderMessage: Codable {
  case getResourceList(Data)
  case getConfiguration(Data)
  case signOut
  case setAuthURL(String)
  case setApiURL(String)
  case setLogFilter(String)
  case setActorName(String)
  case setAccountSlug(String)
  case setInternetResourceEnabled(Bool)
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
    case getConfiguration
    case signOut
    case setAuthURL
    case setApiURL
    case setLogFilter
    case setActorName
    case setAccountSlug
    case setInternetResourceEnabled
    case clearLogs
    case getLogFolderSize
    case exportLogs
    case consumeStopReason
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(MessageType.self, forKey: .type)
    switch type {
    case .setAuthURL:
      let value = try container.decode(String.self, forKey: .value)
      self = .setAuthURL(value)
    case .setApiURL:
      let value = try container.decode(String.self, forKey: .value)
      self = .setApiURL(value)
    case .setLogFilter:
      let value = try container.decode(String.self, forKey: .value)
      self = .setLogFilter(value)
    case .setActorName:
      let value = try container.decode(String.self, forKey: .value)
      self = .setActorName(value)
    case .setAccountSlug:
      let value = try container.decode(String.self, forKey: .value)
      self = .setAccountSlug(value)
    case .setInternetResourceEnabled:
      let value = try container.decode(Bool.self, forKey: .value)
      self = .setInternetResourceEnabled(value)
    case .getResourceList:
      let value = try container.decode(Data.self, forKey: .value)
      self = .getResourceList(value)
    case .getConfiguration:
      let value = try container.decode(Data.self, forKey: .value)
      self = .getConfiguration(value)
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
    case .setAuthURL(let value):
      try container.encode(MessageType.setAuthURL, forKey: .type)
      try container.encode(value, forKey: .value)
    case .setApiURL(let value):
      try container.encode(MessageType.setApiURL, forKey: .type)
      try container.encode(value, forKey: .value)
    case .setLogFilter(let value):
      try container.encode(MessageType.setLogFilter, forKey: .type)
      try container.encode(value, forKey: .value)
    case .setActorName(let value):
      try container.encode(MessageType.setActorName, forKey: .type)
      try container.encode(value, forKey: .value)
    case .setAccountSlug(let value):
      try container.encode(MessageType.setAccountSlug, forKey: .type)
      try container.encode(value, forKey: .value)
    case .setInternetResourceEnabled(let value):
      try container.encode(MessageType.setInternetResourceEnabled, forKey: .type)
      try container.encode(value, forKey: .value)
    case .getResourceList(let value):
      try container.encode(MessageType.getResourceList, forKey: .type)
      try container.encode(value, forKey: .value)
    case .getConfiguration(let value):
      try container.encode(MessageType.getConfiguration, forKey: .type)
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

// swiftlint:enable cyclomatic_complexity
