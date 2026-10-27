//
//  LogFilterTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Testing

@testable import FirezoneKit

@Suite("Log Filter Tests")
struct LogFilterTests {
  @Test(
    "Accepts levels and target=level directives",
    arguments: ["info", "DEBUG", "debug,firezone_tunnel=trace", "warn,hyper=off", "info,"])
  func accepts(_ filter: String) {
    #expect(LogFilter.isValid(filter))
  }

  @Test(
    "Rejects what connlib cannot parse or reads differently",
    arguments: [
      "garbage", "info,foo=bar=baz", "foo[bar]=debug", "=debug", "foo=", "foo=verbose",
      "warn, hyper=off", "info ",
    ])
  func rejects(_ filter: String) {
    #expect(!LogFilter.isValid(filter))
  }
}
