//
//  MenuBar.swift
//
//
//  Created by Jamil Bou Kheir on 4/2/24.
//

// TODO: Refactor to fix file length

import Combine
import Foundation
import NetworkExtension
import OSLog
import Sentry
import SwiftUI

#if os(macOS)
  @MainActor
  // TODO: Refactor to MenuBarExtra for macOS 13+
  // https://developer.apple.com/documentation/swiftui/menubarextra
  public final class MenuBar: NSObject, ObservableObject {
    var statusItem: NSStatusItem
    var lastShownFavorites: [Resource] = []
    var lastShownOthers: [Resource] = []
    // swiftlint:disable:next discouraged_optional_boolean - nil indicates initial unknown state
    var wasInternetResourceEnabled: Bool?
    // swiftlint:disable:next discouraged_optional_boolean - nil indicates initial unknown state
    var wasInternetResourceForced: Bool?
    var cancellables: Set<AnyCancellable> = []
    var updateChecker: UpdateChecker
    var updateMenuDisplayed: Bool = false
    var hideResourceList: Bool
    var signedOutIcon: NSImage?
    var signedInConnectedIcon: NSImage?
    var signedOutIconNotification: NSImage?
    var signedInConnectedIconNotification: NSImage?
    var siteOnlineIcon: NSImage?
    var siteOfflineIcon: NSImage?
    var siteUnknownIcon: NSImage?
    enum AnimationImageIndex: Int {
      case first
      case second
      case last
    }
    var connectingAnimationImages: [AnimationImageIndex: NSImage?] = [:]
    var connectingAnimationImageIndex: Int = 0
    var connectingAnimationTimer: Timer?

    let store: Store

    lazy var menu = NSMenu()

    lazy var signInMenuItem = createMenuItem(
      menu,
      title: "Sign in",
      action: #selector(signInButtonTapped),
      target: self
    )
    lazy var signOutMenuItem = createMenuItem(
      menu,
      title: "Sign out",
      action: #selector(signOutButtonTapped),
      isHidden: true,
      target: self
    )
    lazy var resourcesTitleMenuItem = createMenuItem(
      menu,
      title: "Loading Resources...",
      action: nil,
      isHidden: true,
      target: self
    )
    lazy var resourcesUnavailableMenuItem = createMenuItem(
      menu,
      title: "Resources unavailable",
      action: nil,
      isHidden: true,
      target: self
    )
    lazy var resourcesUnavailableReasonMenuItem = createMenuItem(
      menu,
      title: "",
      action: nil,
      isHidden: true,
      target: self
    )
    lazy var resourcesSeparatorMenuItem = NSMenuItem.separator()
    lazy var otherResourcesMenu: NSMenu = NSMenu()
    lazy var otherResourcesMenuItem: NSMenuItem = {
      let menuItem = NSMenuItem(title: "Other Resources", action: nil, keyEquivalent: "")
      menuItem.submenu = otherResourcesMenu
      return menuItem
    }()
    lazy var otherResourcesSeparatorMenuItem = NSMenuItem.separator()
    lazy var aboutMenuItem: NSMenuItem = {
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
    lazy var adminPortalMenuItem: NSMenuItem = {
      let menuItem = createMenuItem(
        menu,
        title: "Admin Portal...",
        action: #selector(adminPortalButtonTapped),
        target: self
      )
      return menuItem
    }()
    lazy var updateAvailableMenu: NSMenuItem = {
      let menuItem = createMenuItem(
        menu,
        title: "Update available...",
        action: #selector(updateAvailableButtonTapped),
        target: self
      )
      return menuItem
    }()
    lazy var documentationMenuItem: NSMenuItem = {
      let menuItem = createMenuItem(
        menu,
        title: "Documentation...",
        action: #selector(documentationButtonTapped),
        target: self
      )
      return menuItem
    }()
    lazy var supportMenuItem = createMenuItem(
      menu,
      title: "Support...",
      action: #selector(supportButtonTapped),
      target: self
    )
    lazy var helpMenuItem: NSMenuItem = {
      let menuItem = NSMenuItem(title: "Help", action: nil, keyEquivalent: "")
      let subMenu = NSMenu()
      subMenu.addItem(documentationMenuItem)
      subMenu.addItem(supportMenuItem)
      menuItem.submenu = subMenu
      return menuItem
    }()

    lazy var settingsMenuItem = createMenuItem(
      menu,
      title: "Settings",
      action: #selector(settingsButtonTapped),
      key: ",",
      target: self
    )
    lazy var quitMenuItem: NSMenuItem = {
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

    public init(store: Store) {
      statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
      self.store = store
      self.updateChecker = UpdateChecker()
      self.signedOutIcon = NSImage(named: "MenuBarIconSignedOut")
      self.signedInConnectedIcon = NSImage(named: "MenuBarIconSignedInConnected")
      self.signedOutIconNotification = NSImage(named: "MenuBarIconSignedOutNotification")
      self.signedInConnectedIconNotification = NSImage(
        named: "MenuBarIconSignedInConnectedNotification")
      self.siteOnlineIcon = NSImage(named: NSImage.statusAvailableName)
      self.siteOfflineIcon = NSImage(named: NSImage.statusUnavailableName)
      self.siteUnknownIcon = NSImage(named: NSImage.statusNoneName)
      self.connectingAnimationImages[.first] = NSImage(named: "MenuBarIconConnecting1")
      self.connectingAnimationImages[.second] = NSImage(named: "MenuBarIconConnecting2")
      self.connectingAnimationImages[.last] = NSImage(named: "MenuBarIconConnecting3")
      self.hideResourceList = self.store.configuration.publishedHideResourceList

      super.init()

      updateStatusItemIcon()
      createMenu()
      setupObservers()
    }

    // MARK: Responding to state updates

    func setupObservers() {
      // Favorites explicitly sends objectWillChange for lifecycle events. The instance in Store never changes.
      store.favorites.objectWillChange
        .receive(on: DispatchQueue.main)
        .sink(receiveValue: { [weak self] _ in
          guard let self = self else { return }
          self.handleFavoritesChanged()
        }).store(in: &cancellables)

      store.$resourceList
        .receive(on: DispatchQueue.main)
        .sink(receiveValue: { [weak self] _ in
          guard let self = self else { return }
          self.handleResourceListChanged()
        }).store(in: &cancellables)

      store.$vpnStatus
        .receive(on: DispatchQueue.main)
        .sink(receiveValue: { [weak self] _ in
          guard let self = self else { return }
          self.handleStatusChanged()
        }).store(in: &cancellables)

      store.configuration.$publishedInternetResourceEnabled
        .receive(on: DispatchQueue.main)
        .sink(receiveValue: { [weak self] newEnabled in
          guard let self = self else { return }

          if store.configuration.internetResourceEnabled != newEnabled {
            handleResourceListChanged()
          }
        })
        .store(in: &cancellables)

      store.configuration.$publishedHideAdminPortalMenuItem
        .receive(on: DispatchQueue.main)
        .sink(receiveValue: { [weak self] newValue in
          self?.updateConfigurableMenuItems(hideAdminPortalMenuItem: newValue)
        })
        .store(in: &cancellables)

      store.configuration.$publishedHideResourceList
        .receive(on: DispatchQueue.main)
        .sink(receiveValue: { [weak self] newValue in
          self?.hideResourceList = newValue
          self?.handleResourceListChanged()
        })
        .store(in: &cancellables)

      updateChecker.$updateAvailable
        .receive(on: DispatchQueue.main)
        .sink(receiveValue: { [weak self] _ in
          guard let self = self else { return }
          self.handleUpdateAvailableChanged()
        }).store(in: &cancellables)
    }

    func handleFavoritesChanged() {
      // When the user clicks to add or remove a favorite, the menu will close anyway, so just recreate the whole
      // menu. This avoids complex logic when changing in and out of the "nothing is favorited" special case.
      populateResourceMenus([])
      populateResourceMenus(store.resourceList.asArray())
      updateResourcesMenuItems()
    }

    func handleResourceListChanged() {
      populateResourceMenus(store.resourceList.asArray())
      updateResourcesMenuItems()
    }

    func handleStatusChanged() {
      updateStatusItemIcon()
      updateSignInMenuItems()
      quitMenuItem.title = {
        switch store.vpnStatus {
        case .connected, .connecting:
          return "Disconnect and Quit"
        default:
          return "Quit"
        }
      }()
    }

    func handleUpdateAvailableChanged() {
      updateStatusItemIcon()
      refreshUpdateItem()
    }

    func populateResourceMenus(_ newResources: [Resource]) {
      if self.hideResourceList {
        populateFavoriteResourcesMenu([])
        populateOtherResourcesMenu([])
      } else {
        // If we have no favorites, then everything is a favorite
        let hasAnyFavorites = newResources.contains { store.favorites.contains($0.id) }
        let newFavorites =
          if hasAnyFavorites {
            newResources.filter { store.favorites.contains($0.id) || $0.isInternetResource() }
          } else {
            newResources
          }
        let newOthers: [Resource] =
          if hasAnyFavorites {
            newResources.filter { !store.favorites.contains($0.id) && !$0.isInternetResource() }
          } else {
            []
          }

        populateFavoriteResourcesMenu(newFavorites)
        populateOtherResourcesMenu(newOthers)
      }
    }

    func populateFavoriteResourcesMenu(_ newFavorites: [Resource]) {
      // Update the menu in place so everything won't vanish if it's open when it updates
      let diff = (newFavorites).difference(
        from: lastShownFavorites,
        by: { $0 == $1 && !displayNameChanged($0) }
      )

      let index = menu.index(of: resourcesTitleMenuItem) + 1
      for change in diff {
        switch change {
        case .insert(let offset, let element, associatedWith: _):
          let menuItem = createResourceMenuItem(resource: element)
          menu.insertItem(menuItem, at: index + offset)
        case .remove(let offset, element: _, associatedWith: _):
          menu.removeItem(at: index + offset)
        }
      }
      lastShownFavorites = newFavorites
      wasInternetResourceEnabled = store.configuration.internetResourceEnabled
    }

    func populateOtherResourcesMenu(_ newOthers: [Resource]) {
      if newOthers.isEmpty {
        removeItemFromMenu(menu: menu, item: otherResourcesMenuItem)
        removeItemFromMenu(menu: menu, item: otherResourcesSeparatorMenuItem)
      } else {
        let idx = menu.index(of: aboutMenuItem)
        addItemToMenu(menu: menu, item: otherResourcesMenuItem, location: idx)
        addItemToMenu(menu: menu, item: otherResourcesSeparatorMenuItem, location: idx + 1)
      }

      // Update the menu in place so everything won't vanish if it's open when it updates
      let diff = (newOthers).difference(
        from: lastShownOthers,
        by: { $0 == $1 && !displayNameChanged($0) }
      )
      for change in diff {
        switch change {
        case .insert(let offset, let element, associatedWith: _):
          let menuItem = createResourceMenuItem(resource: element)
          otherResourcesMenu.insertItem(menuItem, at: offset)
        case .remove(let offset, element: _, associatedWith: _):
          otherResourcesMenu.removeItem(at: offset)
        }
      }
      lastShownOthers = newOthers
      wasInternetResourceEnabled = store.configuration.internetResourceEnabled
    }

    func updateStatusItemIcon() {
      updateAnimation(status: store.vpnStatus)
      statusItem.button?.image = getStatusIcon(
        status: store.vpnStatus, notification: updateChecker.updateAvailable)
    }

    func updateSignInMenuItems() {
      // Update "Sign In" / "Sign Out" menu items
      switch store.vpnStatus {
      case nil:
        signInMenuItem.title = "Loading VPN configurations from system settings…"
        signInMenuItem.action = nil
        signOutMenuItem.isHidden = true
        settingsMenuItem.target = nil
      case .invalid:
        signInMenuItem.title = "Allow the VPN permission to sign in…"
        signInMenuItem.target = self
        signInMenuItem.action = #selector(grantPermissionMenuItemTapped)
        signOutMenuItem.isHidden = true
        settingsMenuItem.target = nil
      case .disconnected:
        signInMenuItem.title = "Sign In"
        signInMenuItem.target = self
        signInMenuItem.action = #selector(signInButtonTapped)
        signInMenuItem.isEnabled = true
        signOutMenuItem.isHidden = true
        settingsMenuItem.target = self
      case .disconnecting:
        signInMenuItem.title = "Signing out…"
        signInMenuItem.target = self
        signInMenuItem.action = #selector(signInButtonTapped)
        signInMenuItem.isEnabled = false
        signOutMenuItem.isHidden = true
        settingsMenuItem.target = self
      case .connected, .reasserting, .connecting:
        let title = "Signed in as \(store.actorName)"
        signInMenuItem.title = title
        signInMenuItem.target = nil
        signOutMenuItem.isHidden = false
        settingsMenuItem.target = self
      @unknown default:
        break
      }
    }

    // Update resources "header" menu items. An administrator can choose to set a configuration to
    // hide the Resource List at which point we avoid displaying it.
    func updateResourcesMenuItems() {
      if self.hideResourceList {
        resourcesTitleMenuItem.isHidden = true
        resourcesUnavailableMenuItem.isHidden = true
        resourcesUnavailableReasonMenuItem.isHidden = true
        resourcesSeparatorMenuItem.isHidden = true
      } else {
        switch store.vpnStatus {
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
          resourcesTitleMenuItem.title = resourceMenuTitle(store.resourceList)
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
        case nil, .disconnected, .invalid:
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
      }
    }

    func updateConfigurableMenuItems(hideAdminPortalMenuItem: Bool) {
      if hideAdminPortalMenuItem {
        adminPortalMenuItem.isEnabled = false
        adminPortalMenuItem.isHidden = true
      } else {
        adminPortalMenuItem.isEnabled = true
        adminPortalMenuItem.isHidden = false
      }
    }

    // MARK: Menu object lifecycle helpers

    func createMenu() {
      menu.addItem(signInMenuItem)
      menu.addItem(signOutMenuItem)
      menu.addItem(NSMenuItem.separator())

      menu.addItem(resourcesTitleMenuItem)
      menu.addItem(resourcesUnavailableMenuItem)
      menu.addItem(resourcesUnavailableReasonMenuItem)
      menu.addItem(resourcesSeparatorMenuItem)

      if !store.favorites.isEmpty() {
        menu.addItem(otherResourcesMenuItem)
        menu.addItem(otherResourcesSeparatorMenuItem)
      }

      menu.addItem(aboutMenuItem)
      menu.addItem(adminPortalMenuItem)
      menu.addItem(helpMenuItem)
      menu.addItem(settingsMenuItem)
      menu.addItem(NSMenuItem.separator())
      menu.addItem(quitMenuItem)

      menu.delegate = self
      statusItem.menu = menu
    }

    func createMenuItem(
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

    func resourceMenuTitle(_ resources: ResourceList) -> String {
      switch resources {
      case .loading:
        return "Loading Resources..."
      case .loaded(let list):
        if list.isEmpty {
          return "No Resources"
        } else {
          return "Resources"
        }
      }
    }

    func displayNameChanged(_ resource: Resource) -> Bool {
      if !resource.isInternetResource() {
        return false
      }

      return wasInternetResourceEnabled != store.configuration.internetResourceEnabled
    }

    func refreshUpdateItem() {
      // We don't ever need to remove this as the whole menu will be recreated
      // if the user updates, and there's no reason for the update to no longer be available
      // versions should be monotonically increased.
      if updateChecker.updateAvailable && !updateMenuDisplayed {
        updateMenuDisplayed = true
        let index = menu.index(of: settingsMenuItem) + 1
        menu.insertItem(NSMenuItem.separator(), at: index)
        menu.insertItem(updateAvailableMenu, at: index + 1)
      }
    }

    func addItemToMenu(menu: NSMenu, item: NSMenuItem, location: Int) {
      // Adding an item that already exists will crash the process, so check for it first.
      let idx = menu.index(of: otherResourcesMenuItem)
      if idx != -1 {
        // Item's already in the menu, do nothing
        return
      }
      menu.insertItem(otherResourcesMenuItem, at: location)
    }

    func removeItemFromMenu(menu: NSMenu, item: NSMenuItem) {
      // Removing an item that doesn't exist will crash the process, so check for it first.
      let idx = menu.index(of: item)
      if idx == -1 {
        // Item's already not in the menu, do nothing
        return
      }
      menu.removeItem(item)
    }

    func internetResourceTitle(resource: Resource) -> String {
      let status =
        store.configuration.internetResourceEnabled ? StatusSymbol.enabled : StatusSymbol.disabled

      return status + " " + resource.name
    }

    func resourceTitle(resource: Resource) -> String {
      if resource.isInternetResource() {
        return internetResourceTitle(resource: resource)
      }

      return resource.name
    }

    func createResourceMenuItem(resource: Resource) -> NSMenuItem {
      let item = NSMenuItem(
        title: resourceTitle(resource: resource), action: nil, keyEquivalent: "")

      item.isHidden = false
      item.submenu = createSubMenu(resource: resource)

      return item
    }

    func internetResourceToggleTitle() -> String {
      let isEnabled = store.configuration.internetResourceEnabled

      return isEnabled ? "Disable this resource" : "Enable this resource"
    }

    // TODO: Refactor this when refactoring for macOS 13
    func nonInternetResourceHeader(resource: Resource) -> NSMenu {
      let subMenu = NSMenu()

      // Show addressDescription first if it's present
      let resourceAddressDescriptionItem = NSMenuItem()
      if let addressDescription = resource.addressDescription {
        resourceAddressDescriptionItem.title = addressDescription

        if let url = URL(string: addressDescription),
          url.host != nil
        {
          // Looks like a URL, so allow opening it
          resourceAddressDescriptionItem.action = #selector(resourceURLTapped(_:))
          resourceAddressDescriptionItem.toolTip = "Click to open"

          // Using Markdown here only to highlight the URL
          resourceAddressDescriptionItem.attributedTitle =
            try? NSAttributedString(markdown: "[\(addressDescription)](\(addressDescription))")
        } else {
          resourceAddressDescriptionItem.title = addressDescription
          resourceAddressDescriptionItem.action = #selector(resourceValueTapped(_:))
          resourceAddressDescriptionItem.toolTip = "Click to copy"
        }
      } else {
        // Show Address first if addressDescription is missing
        // Address is none only for internet resource
        resourceAddressDescriptionItem.title = resource.address ?? "(no address)"
        resourceAddressDescriptionItem.action = #selector(resourceValueTapped(_:))
      }
      resourceAddressDescriptionItem.isEnabled = true
      resourceAddressDescriptionItem.target = self
      subMenu.addItem(resourceAddressDescriptionItem)

      subMenu.addItem(NSMenuItem.separator())

      let resourceSectionItem = NSMenuItem()
      resourceSectionItem.title = "Resource"
      resourceSectionItem.isEnabled = false
      subMenu.addItem(resourceSectionItem)

      // Resource name
      let resourceNameItem = NSMenuItem()
      resourceNameItem.action = #selector(resourceValueTapped(_:))
      resourceNameItem.title = resource.name
      resourceNameItem.toolTip = "Resource name (click to copy)"
      resourceNameItem.isEnabled = true
      resourceNameItem.target = self
      subMenu.addItem(resourceNameItem)

      // Resource address
      let resourceAddressItem = NSMenuItem()
      resourceAddressItem.action = #selector(resourceValueTapped(_:))
      resourceAddressItem.title = resource.address ?? "(no address)"
      resourceAddressItem.toolTip = "Resource address (click to copy)"
      resourceAddressItem.isEnabled = true
      resourceAddressItem.target = self
      subMenu.addItem(resourceAddressItem)

      let toggleFavoriteItem = NSMenuItem()

      if store.favorites.contains(resource.id) {
        toggleFavoriteItem.action = #selector(removeFavoriteTapped(_:))
        toggleFavoriteItem.title = "Remove from favorites"
        toggleFavoriteItem.toolTip = "Click to remove this Resource from Favorites"
      } else {
        toggleFavoriteItem.action = #selector(addFavoriteTapped(_:))
        toggleFavoriteItem.title = "Add to favorites"
        toggleFavoriteItem.toolTip = "Click to add this Resource to Favorites"
      }
      toggleFavoriteItem.isEnabled = true
      toggleFavoriteItem.representedObject = resource.id
      toggleFavoriteItem.target = self
      subMenu.addItem(toggleFavoriteItem)

      return subMenu
    }

    func internetResourceHeader(resource: Resource) -> NSMenu {
      let subMenu = NSMenu()
      let description = NSMenuItem()

      description.title = "All network traffic"
      description.isEnabled = false

      subMenu.addItem(description)

      // Resource enable / disable toggle
      subMenu.addItem(NSMenuItem.separator())
      let enableToggle = NSMenuItem()
      enableToggle.title = internetResourceToggleTitle()
      enableToggle.target = self
      enableToggle.toolTip = "Enable or disable resource"
      enableToggle.isEnabled = true
      enableToggle.action = #selector(internetResourceToggle(_:))

      subMenu.addItem(enableToggle)

      return subMenu
    }

    func resourceHeader(resource: Resource) -> NSMenu {
      if resource.isInternetResource() {
        internetResourceHeader(resource: resource)
      } else {
        nonInternetResourceHeader(resource: resource)
      }
    }

    func createSubMenu(resource: Resource) -> NSMenu {
      let siteSectionItem = NSMenuItem()
      let siteNameItem = NSMenuItem()
      let siteStatusItem = NSMenuItem()

      let subMenu = resourceHeader(resource: resource)

      // Site details
      if let site = resource.sites.first {
        subMenu.addItem(NSMenuItem.separator())

        siteSectionItem.title = "Site"
        siteSectionItem.isEnabled = false
        subMenu.addItem(siteSectionItem)

        // Site name
        siteNameItem.title = site.name
        siteNameItem.action = #selector(resourceValueTapped(_:))
        siteNameItem.toolTip = "Site name (click to copy)"
        siteNameItem.isEnabled = true
        siteNameItem.target = self
        subMenu.addItem(siteNameItem)

        // Site status
        siteStatusItem.action = #selector(resourceValueTapped(_:))
        siteStatusItem.title = resource.status.toSiteStatus()
        siteStatusItem.toolTip = "\(resource.status.toSiteStatusTooltip()) (click to copy)"
        siteStatusItem.state = statusToState(status: resource.status)
        siteStatusItem.isEnabled = true
        siteStatusItem.target = self
        siteStatusItem.offStateImage = siteOfflineIcon
        if let siteOnlineIcon { siteStatusItem.onStateImage = siteOnlineIcon }
        if let siteUnknownIcon { siteStatusItem.mixedStateImage = siteUnknownIcon }
        subMenu.addItem(siteStatusItem)
      }

      return subMenu
    }

    // MARK: Responding to click events

    @objc func signInButtonTapped() {
      Task {
        do {
          try await WebAuthSession.signIn(store: store)
        } catch {
          Log.error(error)
          MacOSAlert.show(for: error)
        }
      }
    }

    @objc func signOutButtonTapped() {
      Task { do { try await store.signOut() } catch { Log.error(error) } }
    }

    @objc func grantPermissionMenuItemTapped() {
      Task {
        do {
          // If we get here, it means either system extension got disabled or
          // our VPN configuration got removed. Since we don't know which, reinstall
          // the system extension here too just in case. It's a no-op if already
          // installed.
          try await store.systemExtensionRequest(.install)
          try await store.installVPNConfiguration()
        } catch let error as NSError {
          if error.domain == "NEVPNErrorDomain" && error.code == 5 {
            // Warn when the user doesn't click "Allow" on the VPN dialog
            let alert = NSAlert()
            alert.messageText =
              "Firezone requires permission to install VPN configurations. Without it, all functionality will be disabled."
            SentrySDK.pauseAppHangTracking()
            defer { SentrySDK.resumeAppHangTracking() }
            _ = alert.runModal()
          } else {
            throw error
          }
        } catch {
          Log.error(error)
          MacOSAlert.show(for: error)
        }
      }
    }

    @objc func settingsButtonTapped() {
      AppView.WindowDefinition.settings.openWindow()
    }

    @objc func adminPortalButtonTapped() {
      guard let baseURL = URL(string: store.configuration.authURL)
      else {
        Log.warning("Admin portal URL invalid: \(store.configuration.authURL)")
        return
      }

      let accountSlug = store.configuration.accountSlug
      let authURL = baseURL.appendingPathComponent(accountSlug)

      Task { await NSWorkspace.shared.openAsync(authURL) }
    }

    @objc func updateAvailableButtonTapped() {
      Task { await NSWorkspace.shared.openAsync(UpdateChecker.downloadURL()) }
    }

    @objc func documentationButtonTapped() {
      // Static URL literal is guaranteed valid
      // swiftlint:disable:next force_unwrapping
      let url = URL(string: "https://www.firezone.dev/kb?utm_source=macos-client")!

      Task { await NSWorkspace.shared.openAsync(url) }
    }

    @objc func supportButtonTapped() {
      // defaultSupportURL is a static constant guaranteed to be valid
      let url =
        URL(string: store.configuration.supportURL)
        ?? URL(string: Configuration.defaultSupportURL)!  // swiftlint:disable:this force_unwrapping

      Task { await NSWorkspace.shared.openAsync(url) }
    }

    @objc func aboutButtonTapped() {
      NSApp.activate(ignoringOtherApps: true)
      NSApp.orderFrontStandardAboutPanel(self)
    }

    @objc func quitButtonTapped() {
      NSApp.terminate(self)
    }

    @objc func resourceValueTapped(_ sender: AnyObject?) {
      if let value = (sender as? NSMenuItem)?.title {
        copyToClipboard(value)
      }
    }

    @objc func internetResourceToggle(_ sender: NSMenuItem) {
      store.configuration.internetResourceEnabled.toggle()

      sender.title = internetResourceToggleTitle()
    }

    @objc func resourceURLTapped(_ sender: AnyObject?) {
      if let value = (sender as? NSMenuItem)?.title,
        let url = URL(string: value)
      {
        Task { await NSWorkspace.shared.openAsync(url) }
      }
    }

    @objc func addFavoriteTapped(_ sender: NSMenuItem) {
      guard let id = sender.representedObject as? String
      else { fatalError("Expected to receive a String") }

      setFavorited(id: id, favorited: true)
    }

    @objc func removeFavoriteTapped(_ sender: NSMenuItem) {
      guard let id = sender.representedObject as? String
      else { fatalError("Expected to receive a String") }

      setFavorited(id: id, favorited: false)
    }

    // MARK: MenuBar icon animation

    func updateAnimation(status: NEVPNStatus?) {
      switch status {
      case nil, .invalid, .disconnected:
        self.stopConnectingAnimation()
      case .connected:
        self.stopConnectingAnimation()
      case .connecting, .disconnecting, .reasserting:
        self.startConnectingAnimation()
      @unknown default:
        return
      }
    }

    func getStatusIcon(status: NEVPNStatus?, notification: Bool) -> NSImage? {
      if status == .connecting || status == .disconnecting || status == .reasserting {
        // swiftlint:disable:next redundant_nil_coalescing
        return self.connectingAnimationImages[.last] ?? nil
      }

      switch status {
      case nil, .invalid, .disconnected:
        return notification ? self.signedOutIconNotification : self.signedOutIcon
      case .connected:
        return notification ? self.signedInConnectedIconNotification : self.signedInConnectedIcon
      default:
        return nil
      }
    }

    func startConnectingAnimation() {
      guard connectingAnimationTimer == nil else { return }
      let timer = Timer(timeInterval: 0.25, repeats: true) { _ in
        Task { await MainActor.run { self.connectingAnimationShowNextFrame() } }
      }
      RunLoop.main.add(timer, forMode: .common)
      connectingAnimationTimer = timer
    }

    func stopConnectingAnimation() {
      connectingAnimationTimer?.invalidate()
      connectingAnimationTimer = nil
    }

    func connectingAnimationShowNextFrame() {
      guard let currentKey = AnimationImageIndex(rawValue: connectingAnimationImageIndex),
        let image = connectingAnimationImages[currentKey]
      else { return }

      statusItem.button?.image = image
      connectingAnimationImageIndex =
        (connectingAnimationImageIndex + 1) % connectingAnimationImages.count
    }

    // MARK: Other utility functions

    func setFavorited(id: String, favorited: Bool) {
      if favorited {
        store.favorites.add(id)
      } else {
        store.favorites.remove(id)
      }
    }

    func copyToClipboard(_ string: String) {
      let pasteBoard = NSPasteboard.general
      pasteBoard.clearContents()
      // swiftlint:disable:next legacy_objc_type - NSPasteboard.writeObjects requires NSPasteboardWriting
      pasteBoard.writeObjects([string as NSString])
    }

    func showMenu() {
      statusItem.button?.performClick(nil)
    }

    func statusToState(status: ResourceStatus) -> NSControl.StateValue {
      switch status {
      case .offline:
        return .off
      case .online:
        return .on
      case .unknown:
        return .mixed
      }
    }
  }

  extension MenuBar: NSMenuDelegate {
  }
#endif
