//
//  NSWorkspace.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

#if os(macOS)
import AppKit

@MainActor
public extension NSWorkspace {
  func openAsync(_ url: URL) async {
    let configuration = NSWorkspace.OpenConfiguration()
    return await withCheckedContinuation { continuation in
      open(url, configuration: configuration) { _, _ in
        continuation.resume()
      }
    }
  }
}
#endif
