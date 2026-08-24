//
//  LogoTextResourceTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

// Pins that the wordmark SVGs ship with this test target and that NSImage can
// load them: they are what a renderer without a compiled asset catalogue hands
// `LogoText` through `\.logoTextImage`.

#if os(macOS)
  import AppKit
  import Foundation
  import Testing

  struct LogoTextResourceTests {
    @Test("Wordmark SVGs load", arguments: ["LogoText", "LogoTextDark"])
    func wordmarkLoads(name: String) throws {
      let url = try #require(Bundle.module.url(forResource: name, withExtension: "svg"))
      let image = try #require(NSImage(contentsOf: url))

      #expect(image.size.width > 0)
      #expect(image.size.height > 0)
    }
  }
#endif
