//
//  AppStore.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Combine
import OSLog

#if os(macOS)
  import AppKit
#endif

@MainActor
public final class AppStore: ObservableObject {
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
    }
  #endif

  public let tunnelStore: TunnelStore

  private var cancellables: Set<AnyCancellable> = []
  public let logger: AppLogger

  public init() {
    let logger = AppLogger(category: .app, folderURL: SharedAccess.appLogFolderURL)
    let tunnelStore = TunnelStore(logger: logger)

    self.tunnelStore = tunnelStore
    self.logger = logger

    #if os(macOS)
      tunnelStore.$status
        .sink { status in
          Task {
            await MainActor.run {
              if case .invalid = status {
                // Show grant VPN permission when config goes invalid
                WindowDefinition.askPermission.openWindow()
              } else if !DeviceMetadata.firstTime() {
                //
                WindowDefinition.askPermission.window()?.close()
              }
            }
          }
        }
        .store(in: &cancellables)
    #endif
  }
}
