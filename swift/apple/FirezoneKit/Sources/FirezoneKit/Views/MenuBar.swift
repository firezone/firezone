//
//  MenuBar.swift
//  (c) 2023 Firezone, Inc.
//  LICENSE: Apache-2.0
//

// swiftlint:disable function_parameter_count

#if os(macOS)
  import Combine
  import Dependencies
  import OSLog
  import SwiftUI

  @MainActor
  public final class MenuBar {
    let logger = Logger.make(for: MenuBar.self)
    @Dependency(\.mainQueue) private var mainQueue

    private var appStore: AppStore? {
      didSet {
        setupObservers()
      }
    }

    private var cancellables: Set<AnyCancellable> = []
    private var statusItem: NSStatusItem

    let settingsViewModel: SettingsViewModel

    public init(settingsViewModel: SettingsViewModel) {
      self.settingsViewModel = settingsViewModel

      settingsViewModel.onSettingsSaved = {
        // TODO: close settings window and sign in
      }

      statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

      if let button = statusItem.button {
        button.image = NSImage(
          // TODO: Replace with AppIcon when it exists
          systemSymbolName: "circle",
          accessibilityDescription: "Firezone icon"
        )
      }

      createMenu()

      Task {
        let tunnel = try await TunnelStore.loadOrCreate()
        self.appStore = AppStore(tunnelStore: TunnelStore(tunnel: tunnel))
      }
    }

    private func setupObservers() {
      appStore?.auth.$token
        .receive(on: mainQueue)
        .sink { [weak self] token in
          if let token {
            self?.showLoggedIn(token.user)
          } else {
            self?.showLoggedOut()
          }
        }
        .store(in: &cancellables)

      appStore?.tunnel.$status
        .receive(on: mainQueue)
        .sink { [weak self] status in
          if status == .connected {
            self?.connectionMenuItem.title = "Disconnect"
          } else {
            self?.connectionMenuItem.title = "Connect"
          }
        }
        .store(in: &cancellables)
    }

    private lazy var menu = NSMenu()

    private lazy var connectionMenuItem = createMenuItem(
      menu,
      title: "Connect",
      action: #selector(connectButtonTapped),
      target: self
    )

    private lazy var loginMenuItem = createMenuItem(
      menu,
      title: "Login",
      action: #selector(loginButtonTapped),
      target: self
    )
    private lazy var logoutMenuItem = createMenuItem(
      menu,
      title: "Logout",
      action: #selector(logoutButtonTapped),
      isHidden: true,
      target: self
    )
    private lazy var settingsMenuItem = createMenuItem(
      menu,
      title: "Settings",
      action: #selector(settingsButtonTapped),
      target: self
    )
    private lazy var quitMenuItem = createMenuItem(
      menu,
      title: "Quit",
      action: #selector(NSApplication.terminate(_:)),
      key: "q",
      target: nil
    )

    private func createMenu() {
      menu.addItem(connectionMenuItem)
      menu.addItem(loginMenuItem)
      menu.addItem(logoutMenuItem)
      menu.addItem(NSMenuItem.separator())
      menu.addItem(settingsMenuItem)
      menu.addItem(quitMenuItem)

      statusItem.menu = menu
    }

    private func createMenuItem(
      _: NSMenu,
      title: String,
      action: Selector,
      isHidden: Bool = false,
      key: String = "",
      target: AnyObject?
    ) -> NSMenuItem {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: key)

      item.isHidden = isHidden
      item.target = target

      return item
    }

    private func showLoggedIn(_ user: String?) {
      if let user {
        loginMenuItem.title = "Logged in as \(user)"
      } else {
        loginMenuItem.title = "Logged in"
      }
      loginMenuItem.target = nil
      logoutMenuItem.isHidden = false
      connectionMenuItem.isHidden = false
    }

    private func showLoggedOut() {
      loginMenuItem.title = "Login"
      loginMenuItem.target = self

      logoutMenuItem.isHidden = true
      connectionMenuItem.isHidden = true
    }

    @objc private func connectButtonTapped() {
      if appStore?.tunnel.status == .connected {
        appStore?.tunnel.stop()
      } else {
        Task {
          if let token = appStore?.auth.token {
            do {
              try await appStore?.tunnel.start(token: token)
            } catch {
              logger.error("error connecting to tunnel: \(String(describing: error))")
            }
          }
        }
      }
    }

    @objc private func loginButtonTapped() {
      Task {
        do {
          try await appStore?.auth.signIn()
        } catch FirezoneError.missingPortalURL {
          openSettingsWindow()
        } catch {
          logger.error("Error signing in: \(String(describing: error))")
        }
      }
    }

    @objc private func logoutButtonTapped() {
      appStore?.auth.signOut()
    }

    @objc private func settingsButtonTapped() {
      openSettingsWindow()
    }

    private func openSettingsWindow() {
      NSWorkspace.shared.open(URL(string: "firezone://settings")!)
    }
  }
#endif
