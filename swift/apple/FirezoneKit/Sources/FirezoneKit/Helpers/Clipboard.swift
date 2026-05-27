//
//  Clipboard.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

#if os(macOS)
  import AppKit

  enum Clipboard {
    static func copy(_ string: String) {
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.setString(string, forType: .string)
    }
  }
#endif
