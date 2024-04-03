//
//  AppView.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Combine
import SwiftUI
import NetworkExtension
import UserNotifications

/// This is primary view manager for the app. It differs quite a bit between and macOS and
/// iOS so an effort was made to keep the platform-dependent logic as contained as possible.
///
/// The main differences are:
/// - macOS has a menubar which is not a SwiftUI view
/// - iOS has a regular SwiftUI view to show the same
/// - macOS only shows the WelcomeView on first launch (like Windows/Linux)
/// - iOS shows the WelcomeView as it main view for launching auth

@MainActor
public class AppViewModel: ObservableObject {
  let store: Store

  @Published private(set) var status: NEVPNStatus?
  @Published private(set) var decision: UNAuthorizationStatus?

  private var cancellables = Set<AnyCancellable>()

  public init(store: Store) {
    self.store = store

    store.$status
      .receive(on: DispatchQueue.main)
      .sink(receiveValue: { [weak self] status in
        guard let self = self else { return }
        Log.app.log("Status: \(status)")
        
        self.status = status

        #if os(macOS)
        if status == .invalid || DeviceMetadata.firstTime() {
          AppViewModel.WindowDefinition.main.openWindow()
        } else {
          AppViewModel.WindowDefinition.main.window()?.close()
        }
        #endif
      })
      .store(in: &cancellables)

    store.$decision
      .receive(on: DispatchQueue.main)
      .sink(receiveValue: { [weak self] decision in
        guard let self = self else { return }

        Log.app.log("Decision: \(decision)")
        self.decision = decision
      })
      .store(in: &cancellables)
  }
}

public struct AppView: View {
  @ObservedObject var model: AppViewModel

  @State private var isSettingsPresented = false

  public init(model: AppViewModel) {
    self.model = model
  }

  @ViewBuilder
  public var body: some View {
#if os(iOS)
    NavigationView {
      switch (model.status, model.decision) {
      case (nil, _), (_, nil):
        ProgressView()
      case (.invalid, _):
        GrantVPNView(model: GrantVPNViewModel(store: model.store))
      case (.disconnected, .notDetermined):
        GrantNotificationsView(model: GrantNotificationsViewModel(store: model.store))
      case (.disconnected, _):
        WelcomeView(model: WelcomeViewModel(store: model.store))
      case (_, _):
        SessionView(model: SessionViewModel(store: model.store))
      }
    }
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          isSettingsPresented = true
        } label: {
          Label("Settings", systemImage: "gear")
        }
        .disabled(false)
      }
    }
    .sheet(isPresented: $isSettingsPresented) {
      SettingsView(model: SettingsViewModel(store: model.store))
    }
    .navigationViewStyle(StackNavigationViewStyle())
#elseif os(macOS)
      switch model.store.status {
      case .invalid:
        GrantVPNView(model: GrantVPNViewModel(store: model.store))
      default:
        FirstTimeView()
      }
#endif
  }
}

#if os(macOS)
extension AppViewModel {
  public enum WindowDefinition: String, CaseIterable {
    case main = "main"
    case settings = "settings"

    public var identifier: String { "firezone-\(rawValue)" }
    public var externalEventMatchString: String { rawValue }
    public var externalEventOpenURL: URL { URL(string: "firezone://\(rawValue)")! }

    public func openWindow() {
      if let window = NSApp.windows.first(where: {
        $0.identifier?.rawValue.hasPrefix(identifier) ?? false
      }) {
        // Order existing window front
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(self)
      } else {
        // Open new window
        NSWorkspace.shared.open(externalEventOpenURL)
      }
    }

    public func window() -> NSWindow? {
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
