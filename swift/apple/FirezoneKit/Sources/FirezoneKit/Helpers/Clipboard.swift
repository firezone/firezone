//
//  Clipboard.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

#if os(macOS)
  import AppKit
#elseif os(iOS)
  import UIKit
#endif

enum Clipboard {
  static func copy(_ string: String) {
    #if os(macOS)
      let pasteboard = NSPasteboard.general
      pasteboard.clearContents()
      pasteboard.setString(string, forType: .string)
    #elseif os(iOS)
      UIPasteboard.general.string = string
    #endif
  }
}
