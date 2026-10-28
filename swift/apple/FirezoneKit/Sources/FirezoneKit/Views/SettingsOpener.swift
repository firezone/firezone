//
//  SettingsOpener.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

#if os(macOS)
  import AppKit
  import SwiftUI

  /// Hands `content` an action that opens the Settings scene in front of the other apps.
  ///
  /// A menu bar app is not active while its menu is used, so the window would open behind the
  /// frontmost app unless the app is activated too.
  public struct SettingsOpener<Content: View>: View {
    private let content: (@escaping () -> Void) -> Content

    public init(@ViewBuilder content: @escaping (@escaping () -> Void) -> Content) {
      self.content = content
    }

    public var body: some View {
      if #available(macOS 14, *) {
        EnvironmentSettingsOpener(content: content)
      } else {
        content {
          NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
          NSApp.activate(ignoringOtherApps: true)
        }
      }
    }
  }

  @available(macOS 14, *)
  private struct EnvironmentSettingsOpener<Content: View>: View {
    @Environment(\.openSettings) private var openSettings

    let content: (@escaping () -> Void) -> Content

    var body: some View {
      content {
        openSettings()
        NSApp.activate(ignoringOtherApps: true)
      }
    }
  }
#endif
