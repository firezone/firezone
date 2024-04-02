//
//  MainView.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Combine
import NetworkExtension
import OSLog
import SwiftUI

@MainActor
final class MainViewModel: ObservableObject {
  private let logger: AppLogger
  private var cancellables: Set<AnyCancellable> = []
  private let tunnelStore: TunnelStore

  @Published private(set) var resources: [Resource]?

  init(tunnelStore: TunnelStore, logger: AppLogger) {
    self.tunnelStore = tunnelStore
    self.logger = logger

    setupObservers()
  }

  private func setupObservers() {
    Publishers.CombineLatest(
      tunnelStore.$status,
      tunnelStore.$resourceListJSON
    )
    .receive(on: RunLoop.main)
    .sink(receiveValue: { [weak self] status, json in
      guard let self = self else { return }

      if let json = json,
        let data = json.data(using: .utf8)
      {
        resources = try? JSONDecoder().decode([Resource].self, from: data)
      }

      if status == .connected {
        self.tunnelStore.beginUpdatingResources()
      } else {
        self.tunnelStore.endUpdatingResources()
      }
    })
    .store(in: &cancellables)
  }

  func signOutButtonTapped() {
    Task {
      try await tunnelStore.signOut()
    }
  }
}

#if os(macOS)
@MainActor
// TODO: Refactor to MenuBarExtra for macOS 13+
// https://developer.apple.com/documentation/swiftui/menubarextra
public final class MainView: NSObject {
  private var statusItem: NSStatusItem
  private let model: MainViewModel
  private let logger: AppLogger

  private lazy var signedOutIcon = NSImage(named: "MenuBarIconSignedOut")
  private lazy var signedInConnectedIcon = NSImage(named: "MenuBarIconSignedInConnected")

  private lazy var connectingAnimationImages = [
    NSImage(named: "MenuBarIconConnecting1"),
    NSImage(named: "MenuBarIconConnecting2"),
    NSImage(named: "MenuBarIconConnecting3"),
  ]
  private var connectingAnimationImageIndex: Int = 0
  private var connectingAnimationTimer: Timer?

  init(model: MainViewModel, logger: AppLogger) {
    statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    self.model = model
    self.logger = logger
    super.init()

    if let button = statusItem.button {
      button.image = signedOutIcon
    }

    createMenu()
    setupObservers()
  }

  private func setupObservers() {
    tunnelStore.$status
      .receive(on: RunLoop.main)
      .sink(receiveValue: { [weak self] status in
        guard let self = self else { return }

        self.updateStatusItemIcon(status: status)
        self.handleTunnelStatusChanged(status: status)

        if status == .connected {
          tunnelStore.beginUpdatingResources()
        } else {
          logger.log("\(status)")
          tunnelStore.endUpdatingResources()
        }
      }).store(in: &cancellables)

    tunnelStore.$resourceListJSON
      .receive(on: RunLoop.main)
      .sink(receiveValue: { [weak self] json in
        guard let self = self else { return }

        if let json = json,
           let data = json.data(using: .utf8),
           let newResources = try? JSONDecoder().decode([Resource].self, from: data)
        {
          logger.log("received resources: \(json)")
          // Update menu in-place; does a diff against our current resources so send
          // in the new ones before we update our local state
          populateResourceMenu(newResources)
          resourcesTitleMenuItem.title = resourceMenuTitle(newResources)
          resources = newResources
        } else {
          populateResourceMenu(nil)
          resources = nil
        }
      }).store(in: &cancellables)
  }

  private func decodeResources(_ json: String?) -> [Resource]? {
    guard let json = json,
          let data = json.data(using: .utf8)
    else { return nil }

    return try? JSONDecoder().decode([Resource].self, from: data)
  }

  // FIXME: Use SwiftUI for the menubar
  private lazy var menu = NSMenu()

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
    title: "Loading Resources...",
    action: nil,
    isHidden: true,
    target: self
  )
  private lazy var resourcesUnavailableMenuItem = createMenuItem(
    menu,
    title: "Resources unavailable",
    action: nil,
    isHidden: true,
    target: self
  )
  private lazy var resourcesUnavailableReasonMenuItem = createMenuItem(
    menu,
    title: "",
    action: nil,
    isHidden: true,
    target: self
  )
  private lazy var resourcesSeparatorMenuItem = NSMenuItem.separator()
  private lazy var aboutMenuItem: NSMenuItem = {
    let menuItem = createMenuItem(
      menu,
      title: "About",
      action: #selector(aboutButtonTapped),
      target: self
    )
    if let appName = Bundle.main.infoDictionary?[kCFBundleNameKey as String] as? String {
      menuItem.title = "About \(appName)"
    }
    return menuItem
  }()

  private lazy var settingsMenuItem = createMenuItem(
    menu,
    title: "Settings",
    action: #selector(settingsButtonTapped),
    target: nil
  )
  private lazy var quitMenuItem: NSMenuItem = {
    let menuItem = createMenuItem(
      menu,
      title: "Quit",
      action: #selector(quitButtonTapped),
      key: "q",
      target: self
    )
    if let appName = Bundle.main.infoDictionary?[kCFBundleNameKey as String] as? String {
      menuItem.title = "Quit \(appName)"
    }
    return menuItem
  }()

  private func createMenu() {
    menu.addItem(signInMenuItem)
    menu.addItem(signOutMenuItem)
    menu.addItem(NSMenuItem.separator())

    menu.addItem(resourcesTitleMenuItem)
    menu.addItem(resourcesUnavailableMenuItem)
    menu.addItem(resourcesUnavailableReasonMenuItem)
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

  @objc private func signInButtonTapped() {
    WebAuthSession.signIn(tunnelStore: tunnelStore)
  }

  @objc private func signOutButtonTapped() {
    Task {
      try await tunnelStore.signOut()
    }
  }

  @objc private func settingsButtonTapped() {
    AppStore.WindowDefinition.settings.openWindow()
  }

  @objc private func aboutButtonTapped() {
    NSApp.activate(ignoringOtherApps: true)
    NSApp.orderFrontStandardAboutPanel(self)
  }

  @objc private func quitButtonTapped() {
    Task {
      do {
        try await tunnelStore.stop()
      } catch {
        logger.error("\(#function): Error stopping tunnel: \(error)")
      }
      NSApp.terminate(self)
    }
  }

  private func updateStatusItemIcon(status: NEVPNStatus) {
    statusItem.button?.image = {
      switch status {
      case .invalid, .disconnected:
        self.stopConnectingAnimation()
        return self.signedOutIcon
      case .connected:
        self.stopConnectingAnimation()
        return self.signedInConnectedIcon
      case .connecting, .disconnecting, .reasserting:
        self.startConnectingAnimation()
        return self.connectingAnimationImages.last!
      @unknown default:
        return nil
      }
    }()
  }

  private func startConnectingAnimation() {
    guard connectingAnimationTimer == nil else { return }
    let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
      guard let self = self else { return }
      Task {
        await self.connectingAnimationShowNextFrame()
      }
    }
    RunLoop.main.add(timer, forMode: .common)
    connectingAnimationTimer = timer
  }

  private func stopConnectingAnimation() {
    connectingAnimationTimer?.invalidate()
    connectingAnimationTimer = nil
  }

  private func connectingAnimationShowNextFrame() {
    statusItem.button?.image =
    connectingAnimationImages[connectingAnimationImageIndex]
    connectingAnimationImageIndex =
    (connectingAnimationImageIndex + 1) % connectingAnimationImages.count
  }

  private func handleTunnelStatusChanged(status: NEVPNStatus) {
    // Update "Sign In" / "Sign Out" menu items
    switch status {
    case .invalid:
      signInMenuItem.title = "Requires VPN permission"
      signInMenuItem.target = nil
      signOutMenuItem.isHidden = true
      settingsMenuItem.target = nil
    case .disconnected:
      signInMenuItem.title = "Sign In"
      signInMenuItem.target = self
      signInMenuItem.isEnabled = true
      signOutMenuItem.isHidden = true
      settingsMenuItem.target = self
    case .disconnecting:
      signInMenuItem.title = "Signing out..."
      signInMenuItem.target = self
      signInMenuItem.isEnabled = false
      signOutMenuItem.isHidden = true
      settingsMenuItem.target = self
    case .connected, .reasserting, .connecting:
      let title =
      if let actorName = tunnelStore.actorName() {
        "Signed in as \(actorName)"
      } else {
        "Signed in"
      }
      signInMenuItem.title = title
      signInMenuItem.target = nil
      signOutMenuItem.isHidden = false
      settingsMenuItem.target = self
    @unknown default:
      break
    }
    // Update resources "header" menu items
    switch tunnelStore.status {
    case .connecting:
      resourcesTitleMenuItem.isHidden = true
      resourcesUnavailableMenuItem.isHidden = false
      resourcesUnavailableReasonMenuItem.isHidden = false
      resourcesUnavailableReasonMenuItem.target = nil
      resourcesUnavailableReasonMenuItem.title = "Connecting…"
      resourcesSeparatorMenuItem.isHidden = false
    case .connected:
      resourcesTitleMenuItem.isHidden = false
      resourcesUnavailableMenuItem.isHidden = true
      resourcesUnavailableReasonMenuItem.isHidden = true
      resourcesTitleMenuItem.title = resourceMenuTitle(resources)
      resourcesSeparatorMenuItem.isHidden = false
    case .reasserting:
      resourcesTitleMenuItem.isHidden = true
      resourcesUnavailableMenuItem.isHidden = false
      resourcesUnavailableReasonMenuItem.isHidden = false
      resourcesUnavailableReasonMenuItem.target = nil
      resourcesUnavailableReasonMenuItem.title = "No network connectivity"
      resourcesSeparatorMenuItem.isHidden = false
    case .disconnecting:
      resourcesTitleMenuItem.isHidden = true
      resourcesUnavailableMenuItem.isHidden = false
      resourcesUnavailableReasonMenuItem.isHidden = false
      resourcesUnavailableReasonMenuItem.target = nil
      resourcesUnavailableReasonMenuItem.title = "Disconnecting…"
      resourcesSeparatorMenuItem.isHidden = false
    case .disconnected, .invalid:
      // We should never be in a state where the tunnel is
      // down but the user is signed in, but we have
      // code to handle it just for the sake of completion.
      resourcesTitleMenuItem.isHidden = true
      resourcesUnavailableMenuItem.isHidden = true
      resourcesUnavailableReasonMenuItem.isHidden = true
      resourcesUnavailableReasonMenuItem.title = "Disconnected"
      resourcesSeparatorMenuItem.isHidden = true
    @unknown default:
      break
    }
    quitMenuItem.title = {
      switch status {
      case .connected, .connecting:
        return "Disconnect and Quit"
      default:
        return "Quit"
      }
    }()
  }

  private func resourceMenuTitle(_ newResources: [Resource]?) -> String {
    guard let newResources = newResources else { return "Loading Resources..." }

    if newResources.isEmpty {
      return "No Resources"
    } else {
      return "Resources"
    }
  }

  private func populateResourceMenu(_ newResources: [Resource]?) {
    // the menu contains other things besides resources, so update it in-place
    let diff = (newResources ?? []).difference(
      from: resources ?? [],
      by: { $0.name == $1.name && $0.address == $1.address }
    )
    let index = menu.index(of: resourcesTitleMenuItem) + 1
    for change in diff {
      switch change {
      case .insert(let offset, let element, associatedWith: _):
        let menuItem = createResourceMenuItem(title: element.name, submenuTitle: element.address)
        menu.insertItem(menuItem, at: index + offset)
      case .remove(let offset, element: _, associatedWith: _):
        menu.removeItem(at: index + offset)
      }
    }
  }

  private func createResourceMenuItem(title: String, submenuTitle: String) -> NSMenuItem {
    let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")

    let subMenu = NSMenu()
    let subMenuItem = NSMenuItem(
      title: submenuTitle, action: #selector(resourceValueTapped(_:)), keyEquivalent: ""
    )
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
}
#endif

#if os(iOS)
  struct MainView: View {
    @ObservedObject var model: MainViewModel

    var body: some View {
      List {
        Section(header: Text("Authentication")) {
          Group {
            if case .connected = model.tunnelStore.status {
              let actorName = model.tunnelStore.actorName() ?? ""
              HStack {
                Text(actorName.isEmpty ? "Signed in" : "Signed in as")
                Spacer()
                Text(actorName).foregroundColor(.secondary)
              }
              HStack {
                Spacer()
                Button("Sign Out") {
                  model.signOutButtonTapped()
                }
                Spacer()
              }
            } else {
              Text(model.tunnelStore.status.description)
            }
          }
        }
        if case .connected = model.tunnelStore.status {
          Section(header: Text("Resources")) {
            if let resources = model.resources {
              if resources.isEmpty {
                Text("No Resources")
              } else {
                ForEach(resources) { resource in
                  Menu(
                    content: {
                      Button {
                        copyResourceTapped(resource)
                      } label: {
                        Label("Copy Address", systemImage: "doc.on.doc")
                      }
                    },
                    label: {
                      HStack {
                        Text(resource.name)
                          .foregroundColor(.primary)
                        Spacer()
                        Text(resource.address)
                          .foregroundColor(.secondary)
                      }
                    })
                }
              }
            } else {
              Text("Loading Resources...")
            }
          }
        }
      }
      .listStyle(GroupedListStyle())
      .navigationTitle("Firezone")
    }

    private func copyResourceTapped(_ resource: Resource) {
      let pasteboard = UIPasteboard.general
      pasteboard.string = resource.address
    }
  }
#endif
