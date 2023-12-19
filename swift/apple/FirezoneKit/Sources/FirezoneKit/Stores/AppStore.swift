//
//  AppStore.swift
//  (c) 2023 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Combine
import Dependencies
import OSLog

#if os(macOS)
  import AppKit
#endif

@MainActor
public final class AppStore: ObservableObject {
  private let logger = Logger.make(for: AppStore.self)

  @Dependency(\.authStore) var auth
  @Dependency(\.mainQueue) var mainQueue

  #if os(macOS)
    public enum WindowDefinition: String, CaseIterable {
      case askPermission = "ask-permission"
      case settings = "settings"

      public var identifier: String { "firezone-\(rawValue)" }
      public var externalEventMatchString: String { rawValue }
      public var externalEventOpenURL: URL { URL(string: "firezone://\(rawValue)")! }

      @MainActor
      public func bringAlreadyOpenWindowFront() {
        if let window = NSApp.windows.first(where: {
          $0.identifier?.rawValue.hasPrefix(identifier) ?? false
        }) {
          NSApp.activate(ignoringOtherApps: true)
          window.makeKeyAndOrderFront(self)
        }
      }

      @MainActor
      public func openWindow() {
        if let window = NSApp.windows.first(where: {
          $0.identifier?.rawValue.hasPrefix(identifier) ?? false
        }) {
          NSApp.activate(ignoringOtherApps: true)
          window.makeKeyAndOrderFront(self)
        } else {
          NSWorkspace.shared.open(externalEventOpenURL)
        }
      }

      @MainActor
      public func window() -> NSWindow? {
        NSApp.windows.first { window in
          if let windowId = window.identifier?.rawValue {
            return windowId.hasPrefix(self.identifier)
          }
          return false
        }
      }

      public static func allIdentifiers() -> [String] {
        AppStore.WindowDefinition.allCases.map { $0.identifier }
      }
    }
  #endif

  let tunnel: TunnelStore
  private var cancellables: Set<AnyCancellable> = []

  public init(tunnelStore: TunnelStore) {
    tunnel = tunnelStore

    #if os(macOS)
      tunnelStore.$tunnelAuthStatus
        .sink { tunnelAuthStatus in

          if case .noTunnelFound = tunnelAuthStatus {
            Task {
              await MainActor.run {
                WindowDefinition.askPermission.openWindow()
              }
            }
          }
        }
        .store(in: &cancellables)
    #endif

  }

  private func signOutAndStopTunnel() {
    Task {
      do {
        try await tunnel.stop()
        await auth.signOut()
      } catch {
        logger.error("\(#function): Error stopping tunnel: \(String(describing: error))")
      }
    }
  }
}
