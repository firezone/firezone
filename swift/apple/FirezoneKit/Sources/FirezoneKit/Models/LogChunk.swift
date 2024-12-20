//
//  LogChunk.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation

public struct LogChunk: Codable {
  public var done: Bool
  public var data: Data

  public init(done: Bool, data: Data) {
    self.done = done
    self.data = data
  }
}
