//
//  StatusItemIntrospection.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//
//  Minimal implementation for accessing NSStatusItem from SwiftUI MenuBarExtra.
//  Inspired by orchetect/MenuBarExtraAccess (MIT License).
//  See: https://github.com/orchetect/MenuBarExtraAccess
//

#if os(macOS)
  import AppKit

  /// Provides access to the NSStatusItem underlying a SwiftUI MenuBarExtra.
  ///
  /// SwiftUI's MenuBarExtra doesn't expose its NSStatusItem directly, but we need it
  /// for programmatic control (e.g., opening the menu). This utility finds the status
  /// item by introspecting the app's windows.
  @MainActor
  public enum StatusItemIntrospection {
    /// Finds the NSStatusItem for our MenuBarExtra.
    ///
    /// - Returns: The NSStatusItem if found, nil otherwise
    public static func statusItem() -> NSStatusItem? {
      for window in NSApp.windows {
        let className = String(describing: type(of: window))
        guard className.contains("NSStatusBarWindow") else { continue }

        guard let statusItem = window.value(forKey: "statusItem") as? NSStatusItem else {
          continue
        }

        // Filter out replica items (used for inactive spaces/screens).
        // We only want the main NSStatusItem, not NSStatusItemReplicant subclasses.
        let itemClassName = String(describing: type(of: statusItem))
        if itemClassName == "NSStatusItem" || itemClassName == "NSSceneStatusItem" {
          return statusItem
        }
      }
      return nil
    }
  }
#endif
