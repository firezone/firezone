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
public final class MenuBar: NSObject {
    let logger = Logger.make(for: MenuBar.self)
    @Dependency(\.mainQueue) private var mainQueue

    public private(set) var appStore: AppStore? {
      didSet {
        setupObservers()
      }
    }

    private var cancellables: Set<AnyCancellable> = []
    private var statusItem: NSStatusItem
    private var orderedResources: [DisplayableResources.Resource] = []
    private var isMenuVisible = false {
      didSet { handleMenuVisibilityOrStatusChanged() }
    }
    private lazy var disconnectedIcon = NSImage(named: "MenuBarIconDisconnected")
    private lazy var connectedIcon = NSImage(named: "MenuBarIconConnected")

    let settingsViewModel: SettingsViewModel

    public init(settingsViewModel: SettingsViewModel) {
      self.settingsViewModel = settingsViewModel

      settingsViewModel.onSettingsSaved = {
        // TODO: close settings window and sign in
      }

      statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

      super.init()
      createMenu()

      if let button = statusItem.button {
        button.image = disconnectedIcon
      }

      Task {
        let tunnel = try await TunnelStore.loadOrCreate()
        self.appStore = AppStore(tunnelStore: TunnelStore(tunnel: tunnel))
      }
    }

    private func setupObservers() {
      appStore?.auth.$authResponse
        .receive(on: mainQueue)
        .sink { [weak self] authResponse in
          if let authResponse {
            self?.showSignedIn(authResponse.actorName)
          } else {
            self?.showSignedOut()
          }
        }
        .store(in: &cancellables)

      appStore?.tunnel.$status
        .receive(on: mainQueue)
        .sink { [weak self] status in
          if status == .connected {
            self?.connectionMenuItem.title = "Disconnect"
            self?.statusItem.button?.image = self?.connectedIcon
          } else {
            self?.connectionMenuItem.title = "Connect"
            self?.statusItem.button?.image = self?.disconnectedIcon
          }
          self?.handleMenuVisibilityOrStatusChanged()
          if status != .connected {
            self?.setOrderedResources([])
          }
        }
        .store(in: &cancellables)

      appStore?.tunnel.$resources
        .receive(on: mainQueue)
        .sink { [weak self] resources in
          guard let self = self else { return }
          self.setOrderedResources(resources.orderedResources)
        }
        .store(in: &cancellables)
    }

    private lazy var menu = NSMenu()

    private lazy var connectionMenuItem = createMenuItem(
      menu,
      title: "Connect",
      action: #selector(connectButtonTapped),
      isHidden: true,
      target: self
    )

    private lazy var signInMenuItem = createMenuItem(
      menu,
      title: "Sign in",
      action: #selector(signInButtonTapped),
      target: self
    )
    private lazy var signOutMenuItem = createMenuItem(
      menu,
      title: "Sign out",
      action: #selector(signOutButtonTapped),
      isHidden: true,
      target: self
    )
    private lazy var resourcesTitleMenuItem = createMenuItem(
      menu,
      title: "No Resources",
      action: nil,
      isHidden: false,
      target: self
    )
    private lazy var resourcesSeparatorMenuItem = NSMenuItem.separator()
    private lazy var aboutMenuItem = createMenuItem(
      menu,
      title: "About",
      action: #selector(aboutButtonTapped),
      target: self
    )
    private lazy var settingsMenuItem = createMenuItem(
      menu,
      title: "Settings",
      action: #selector(settingsButtonTapped),
      target: self
    )
    private lazy var quitMenuItem: NSMenuItem = {
      let menuItem = createMenuItem(
        menu,
        title: "Quit",
        action: #selector(NSApplication.terminate(_:)),
        key: "q",
        target: nil
      )
      if let appName = Bundle.main.infoDictionary?[kCFBundleNameKey as String] as? String {
        menuItem.title = "Quit \(appName)"
      }
      return menuItem
    }()

    private func createMenu() {
      menu.addItem(connectionMenuItem)
      menu.addItem(signInMenuItem)
      menu.addItem(signOutMenuItem)
      menu.addItem(NSMenuItem.separator())

      menu.addItem(resourcesTitleMenuItem)
      menu.addItem(resourcesSeparatorMenuItem)

      menu.addItem(aboutMenuItem)
      menu.addItem(settingsMenuItem)
      menu.addItem(quitMenuItem)

      menu.delegate = self

      statusItem.menu = menu
    }

    private func createMenuItem(
      _: NSMenu,
      title: String,
      action: Selector?,
      isHidden: Bool = false,
      key: String = "",
      target: AnyObject?
    ) -> NSMenuItem {
      let item = NSMenuItem(title: title, action: action, keyEquivalent: key)

      item.isHidden = isHidden
      item.target = target
      item.isEnabled = (action != nil)

      return item
    }

    private func showSignedIn(_ user: String?) {
      if let user {
        signInMenuItem.title = "Signed in as \(user)"
      } else {
        signInMenuItem.title = "Signed in"
      }
      signInMenuItem.target = nil
      signOutMenuItem.isHidden = false
    }

    private func showSignedOut() {
      signInMenuItem.title = "Sign in"
      signInMenuItem.target = self

      signOutMenuItem.isHidden = true
    }

    @objc private func connectButtonTapped() {
      if appStore?.tunnel.status == .connected {
        appStore?.tunnel.stop()
      } else {
        Task {
          if let authResponse = appStore?.auth.authResponse {
            do {
              try await appStore?.tunnel.start(authResponse: authResponse)
            } catch {
              logger.error("error connecting to tunnel: \(String(describing: error)) -- signing out")
              appStore?.auth.signOut()
            }
          }
        }
      }
    }

    @objc private func signInButtonTapped() {
      Task {
        do {
          try await appStore?.auth.signIn()
        } catch FirezoneError.missingTeamId {
          openSettingsWindow()
        } catch {
          logger.error("Error signing in: \(String(describing: error))")
        }
      }
    }

    @objc private func signOutButtonTapped() {
      appStore?.auth.signOut()
    }

    @objc private func settingsButtonTapped() {
      openSettingsWindow()
    }

    @objc private func aboutButtonTapped() {
      NSApp.activate(ignoringOtherApps: true)
      NSApp.orderFrontStandardAboutPanel(self)
    }

    private func openSettingsWindow() {
      NSWorkspace.shared.open(URL(string: "firezone://settings")!)
    }

    private func handleMenuVisibilityOrStatusChanged() {
      guard let appStore = appStore else { return }
      let status = appStore.tunnel.status
      if isMenuVisible && status == .connected {
        appStore.tunnel.beginUpdatingResources()
      } else {
        appStore.tunnel.endUpdatingResources()
      }
      resourcesTitleMenuItem.isHidden = (status != .connected)
      resourcesSeparatorMenuItem.isHidden = (status != .connected)
    }

    private func setOrderedResources(_ newOrderedResources: [DisplayableResources.Resource]) {
      let diff = newOrderedResources.difference(
        from: self.orderedResources,
        by: { $0.name == $1.name && $0.location == $1.location }
      )
      let baseIndex = menu.index(of: resourcesTitleMenuItem) + 1
      for change in diff {
        switch change {
          case .insert(offset: let offset, element: let element, associatedWith: _):
            let menuItem = createResourceMenuItem(title: element.name, submenuTitle: element.location)
            menu.insertItem(menuItem, at: baseIndex + offset)
            orderedResources.insert(element, at: offset)
          case .remove(offset: let offset, element: _, associatedWith: _):
            menu.removeItem(at: baseIndex + offset)
            orderedResources.remove(at: offset)
        }
      }
      resourcesTitleMenuItem.title = orderedResources.isEmpty ? "No Resources" : "Resources"
    }

    private func createResourceMenuItem(title: String, submenuTitle: String) -> NSMenuItem {
      let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")

      let subMenu = NSMenu()
      let subMenuItem = NSMenuItem(title: submenuTitle, action: #selector(resourceValueTapped(_:)), keyEquivalent: "")
      subMenuItem.isEnabled = true
      subMenuItem.target = self
      subMenu.addItem(subMenuItem)

      item.isHidden = false
      item.submenu = subMenu

      return item
    }

    @objc private func resourceValueTapped(_ sender: AnyObject?) {
      if let value = (sender as? NSMenuItem)?.title {
        copyToClipboard(value)
      }
    }

    private func copyToClipboard(_ string: String) {
      let pasteBoard = NSPasteboard.general
      pasteBoard.clearContents()
      pasteBoard.writeObjects([string as NSString])
    }
  }

  extension MenuBar: NSMenuDelegate {
    public func menuNeedsUpdate(_ menu: NSMenu) {
      isMenuVisible = true
    }
    public func menuDidClose(_ menu: NSMenu) {
      isMenuVisible = false
    }
  }
#endif
