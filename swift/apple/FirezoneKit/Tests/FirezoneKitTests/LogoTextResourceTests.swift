//
//  LogoTextResourceTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

// Pins that the wordmark PNGs land in the package bundle where `LogoText` loads
// them from, whichever build system produced the bundle.

import Foundation
import Testing

#if os(macOS)
  import AppKit
#endif

@testable import FirezoneKit

struct LogoTextResourceTests {
  @Test("Wordmark PNGs are in the package bundle", arguments: ["LogoText", "LogoTextDark"])
  func wordmarkResolves(name: String) {
    #expect(Bundle.module.url(forResource: name, withExtension: "png") != nil)
    #expect(Bundle.module.url(forResource: "\(name)@2x", withExtension: "png") != nil)

    #if os(macOS)
      #expect(Bundle.module.urlForImageResource(name) != nil)
    #endif
  }
}
