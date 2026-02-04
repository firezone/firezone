//
//  MenuBarIconTests.swift
//  (c) 2025 Firezone, Inc.
//  LICENSE: Apache-2.0
//

#if os(macOS)
  import NetworkExtension
  import Testing

  @testable import FirezoneKit

  @Suite("Menu Bar Icon Tests")
  struct MenuBarIconTests {

    // MARK: - Disconnected States

    @Test("nil status without update shows signed out icon")
    func nilStatusNoUpdate() {
      let icon = Store.menuBarIcon(for: nil, updateAvailable: false)
      #expect(icon == "MenuBarIconSignedOut")
    }

    @Test("nil status with update shows signed out notification icon")
    func nilStatusWithUpdate() {
      let icon = Store.menuBarIcon(for: nil, updateAvailable: true)
      #expect(icon == "MenuBarIconSignedOutNotification")
    }

    @Test("invalid status without update shows signed out icon")
    func invalidStatusNoUpdate() {
      let icon = Store.menuBarIcon(for: .invalid, updateAvailable: false)
      #expect(icon == "MenuBarIconSignedOut")
    }

    @Test("invalid status with update shows signed out notification icon")
    func invalidStatusWithUpdate() {
      let icon = Store.menuBarIcon(for: .invalid, updateAvailable: true)
      #expect(icon == "MenuBarIconSignedOutNotification")
    }

    @Test("disconnected status without update shows signed out icon")
    func disconnectedStatusNoUpdate() {
      let icon = Store.menuBarIcon(for: .disconnected, updateAvailable: false)
      #expect(icon == "MenuBarIconSignedOut")
    }

    @Test("disconnected status with update shows signed out notification icon")
    func disconnectedStatusWithUpdate() {
      let icon = Store.menuBarIcon(for: .disconnected, updateAvailable: true)
      #expect(icon == "MenuBarIconSignedOutNotification")
    }

    // MARK: - Connected State

    @Test("connected status without update shows connected icon")
    func connectedStatusNoUpdate() {
      let icon = Store.menuBarIcon(for: .connected, updateAvailable: false)
      #expect(icon == "MenuBarIconSignedInConnected")
    }

    @Test("connected status with update shows connected notification icon")
    func connectedStatusWithUpdate() {
      let icon = Store.menuBarIcon(for: .connected, updateAvailable: true)
      #expect(icon == "MenuBarIconSignedInConnectedNotification")
    }

    // MARK: - Transitional States

    @Test("connecting status shows connecting icon regardless of update")
    func connectingStatus() {
      #expect(
        Store.menuBarIcon(for: .connecting, updateAvailable: false) == "MenuBarIconConnecting3")
      #expect(
        Store.menuBarIcon(for: .connecting, updateAvailable: true) == "MenuBarIconConnecting3")
    }

    @Test("disconnecting status shows connecting icon regardless of update")
    func disconnectingStatus() {
      #expect(
        Store.menuBarIcon(for: .disconnecting, updateAvailable: false) == "MenuBarIconConnecting3")
      #expect(
        Store.menuBarIcon(for: .disconnecting, updateAvailable: true) == "MenuBarIconConnecting3")
    }

    @Test("reasserting status shows connecting icon regardless of update")
    func reassertingStatus() {
      #expect(
        Store.menuBarIcon(for: .reasserting, updateAvailable: false) == "MenuBarIconConnecting3")
      #expect(
        Store.menuBarIcon(for: .reasserting, updateAvailable: true) == "MenuBarIconConnecting3")
    }
  }
#endif
