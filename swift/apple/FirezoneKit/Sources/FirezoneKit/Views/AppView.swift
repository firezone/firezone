//
//  AppView.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Combine
import NetworkExtension
import SwiftUI
import UserNotifications

/// This is the primary view manager for the app. It differs quite a bit between and macOS and
/// iOS so an effort was made to keep the platform-dependent logic as contained as possible.
///
/// The main differences are:
/// - macOS has a menubar which is not a SwiftUI view
/// - iOS has a regular SwiftUI view to show the same
/// - macOS only shows the WelcomeView on first launch (like Windows/Linux)
/// - iOS shows the WelcomeView as it main view for launching auth

public struct AppView: View {
  @EnvironmentObject var store: Store

#if os(macOS)
  // This is a static function because the Environment Object is not present at initialization time when we want to
  // subscribe the AppView to certain Store properties to control the main window lifecycle which SwiftUI doesn't
  // handle.
  private static var cancellables: Set<AnyCancellable> = []
  public static func subscribeToGlobalEvents(store: Store) {
    store.$status
      .combineLatest(store.$systemExtensionStatus)
      .receive(on: DispatchQueue.main)
      .sink(receiveValue: { status, systemExtensionStatus in
        // Open window in case permissions are revoked
        if status == .invalid || systemExtensionStatus != .installed {
          WindowDefinition.main.openWindow()
        }

        // Close window upon launch for day-to-day use
        if status != .invalid && systemExtensionStatus == .installed && FirezoneId.load(.pre140) != nil {
          WindowDefinition.main.window()?.close()
        }
      })
      .store(in: &cancellables)
  }

  public enum WindowDefinition: String, CaseIterable {
    case main
    case settings

    public var identifier: String { "firezone-\(rawValue)" }
    public var externalEventMatchString: String { rawValue }
    public var externalEventOpenURL: URL { URL(string: "firezone://\(rawValue)")! }

    @MainActor public func openWindow() {
      if let window = NSApp.windows.first(where: {
        $0.identifier?.rawValue.hasPrefix(identifier) ?? false
      }) {
        // Order existing window front
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(self)
      } else {
        // Open new window
        Task { await NSWorkspace.shared.openAsync(externalEventOpenURL) }
      }
    }

    @MainActor public func window() -> NSWindow? {
      NSApp.windows.first { window in
        if let windowId = window.identifier?.rawValue {
          return windowId.hasPrefix(self.identifier)
        }
        return false
      }
    }
  }
#endif

  public init() {}

  @ViewBuilder
  public var body: some View {
#if os(iOS)
    switch (store.status, store.decision) {
    case (nil, _), (_, nil):
      ProgressView()
    case (.invalid, _):
      GrantVPNView()
    case (_, .notDetermined):
      GrantNotificationsView()
    case (.disconnected, _):
      iOSNavigationView {
        WelcomeView()
      }
    case (_, _):
      iOSNavigationView {
        SessionView()
      }
    }
#elseif os(macOS)
    switch (store.systemExtensionStatus, store.status) {
    case (nil, nil):
      ProgressView()
    case (.needsInstall, _), (_, .invalid):
      GrantVPNView()
    default:
      FirstTimeView()
    }
#endif
  }
}
