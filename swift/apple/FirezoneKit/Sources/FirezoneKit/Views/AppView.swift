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

@MainActor
public class AppViewModel: ObservableObject {
  let favorites: Favorites
  let store: Store
  let sessionNotification: SessionNotification

  @Published private(set) var status: NEVPNStatus?
  @Published private(set) var decision: UNAuthorizationStatus?

  private var cancellables = Set<AnyCancellable>()

  public init(favorites: Favorites, store: Store) {
    self.favorites = favorites
    self.store = store
    self.sessionNotification = SessionNotification()

    self.sessionNotification.signInHandler = {
      Task {
        do { try await WebAuthSession.signIn(store: self.store) } catch { Log.error(error) }
      }
    }

    Task {
      // Load user's decision whether to allow / disallow notifications
      let decision = await self.sessionNotification.loadAuthorizationStatus()
      updateNotificationDecision(to: decision)

      // Load VPN configuration and system extension status
      do {
        try await self.store.bindToVPNConfigurationUpdates()
        let vpnConfigurationStatus = self.store.status

#if os(macOS)
        let systemExtensionStatus = try await self.store.checkedSystemExtensionStatus()

        if systemExtensionStatus != .installed
          || vpnConfigurationStatus == .invalid {

          // Show the main Window if VPN permission needs to be granted
          AppViewModel.WindowDefinition.main.openWindow()
        } else {
          AppViewModel.WindowDefinition.main.window()?.close()
        }
#endif

        if vpnConfigurationStatus == .disconnected {

          // Try to connect on start
          try self.store.vpnConfigurationManager.start()
        }
      } catch {
        Log.error(error)
      }
    }

    store.$status
      .receive(on: DispatchQueue.main)
      .sink(receiveValue: { [weak self] status in
        guard let self = self else { return }

        self.status = status
      })
      .store(in: &cancellables)
  }

  func updateNotificationDecision(to newStatus: UNAuthorizationStatus) {
    self.decision = newStatus
  }
}

public struct AppView: View {
  @ObservedObject var model: AppViewModel

  public init(model: AppViewModel) {
    self.model = model
  }

  @ViewBuilder
  public var body: some View {
#if os(iOS)
    switch (model.status, model.decision) {
    case (nil, _), (_, nil):
      ProgressView()
    case (.invalid, _):
      GrantVPNView(model: GrantVPNViewModel(store: model.store))
    case (_, .notDetermined):
      GrantNotificationsView(model: GrantNotificationsViewModel(
        sessionNotification: model.sessionNotification,
        onDecisionChanged: { decision in
          model.updateNotificationDecision(to: decision)
        }
      ))
    case (.disconnected, _):
      iOSNavigationView(model: model) {
        WelcomeView(model: WelcomeViewModel(store: model.store))
      }
    case (_, _):
      iOSNavigationView(model: model) {
        SessionView(model: SessionViewModel(favorites: model.favorites, store: model.store))
      }
    }
#elseif os(macOS)
    switch (model.store.systemExtensionStatus, model.status) {
    case (nil, nil):
      ProgressView()
    case (.needsInstall, _), (_, .invalid):
      GrantVPNView(model: GrantVPNViewModel(store: model.store))
    default:
      FirstTimeView()
    }
#endif
  }
}

#if os(macOS)
public extension AppViewModel {
  enum WindowDefinition: String, CaseIterable {
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
}
#endif
