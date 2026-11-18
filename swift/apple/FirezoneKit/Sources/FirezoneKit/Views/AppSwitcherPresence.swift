//
//  AppSwitcherPresence.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

#if os(macOS)
  import AppKit
  import SwiftUI

  /// The windows that want the app listed in the Dock and the app switcher.
  ///
  /// The app is an agent (`LSUIElement`), which both leave out, so it turns into a
  /// regular app for as long as one of these windows is open.
  @MainActor
  private enum AppSwitcherPresence {
    private static var windows: Set<UUID> = []

    static func add(_ window: UUID) {
      windows.insert(window)
      NSApp.setActivationPolicy(.regular)
    }

    static func remove(_ window: UUID) {
      windows.remove(window)

      if windows.isEmpty {
        NSApp.setActivationPolicy(.accessory)
      }
    }
  }

  private struct ListedInAppSwitcher: ViewModifier {
    @State private var window = UUID()

    func body(content: Content) -> some View {
      content
        .onAppear { AppSwitcherPresence.add(window) }
        .onDisappear { AppSwitcherPresence.remove(window) }
    }
  }

  extension View {
    /// Lists the app in the Dock and the app switcher while the window showing this view is open.
    public func listedInAppSwitcher() -> some View {
      modifier(ListedInAppSwitcher())
    }
  }
#endif
