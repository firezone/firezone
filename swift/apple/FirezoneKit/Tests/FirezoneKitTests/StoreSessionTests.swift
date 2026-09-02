//
//  StoreSessionTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

#if os(macOS)
  import Foundation
  import NetworkExtension
  import Testing

  @testable import FirezoneKit

  /// Runs a session through the real `Store` against the mocked extension, entered the way
  /// a user enters it: the app starts, they sign in, what the tunnel reports arrives, they
  /// act on it, and the session ends. The only thing standing in for production is the
  /// extension. What the mock reports has to come out of the store, and what the store
  /// does has to reach the mock.
  ///
  /// Serialised because every `Store` loads into the process-wide `Configuration`.
  @MainActor
  @Suite("Store session", .serialized)
  struct StoreSessionTests {
    private static let token = "stored-token"

    // The deployment the screenshot fixtures describe, so the galleries and these tests
    // tell one story.
    private static let engineeringWiki = Resource(
      id: "0854dca1-2c5b-468a-be85-0eec2f02a211",
      name: "Engineering wiki",
      address: "wiki.example.com",
      addressDescription: "https://wiki.example.com",
      status: .online,
      sites: [Site(id: "917e9354-26b3-4704-867c-f84c8688d269", name: "Sydney Office")],
      type: .dns
    )

    private static let benchController = ConnectedDevice(
      id: "a21c9663-4d0e-4f4a-a8fa-48790b1e5cef",
      name: "bench-controller-01",
      tunIPv4: "100.64.3.18",
      tunIPv6: "fd00:2021:1111::12",
      pools: ["Lab hardware", "Shared storage"]
    )

    @Test("signing in starts the tunnel with the token")
    func signingInStartsTheTunnelWithTheToken() async throws {
      let app = try await signedOut()

      try await app.store.signIn(token: Self.token)

      #expect(app.tunnel.startOptions?["authentication"] as? String == "tokenAndCertificate")
      #expect(app.tunnel.startOptions?["token"] as? String == Self.token)
      try await waitUntil { app.store.vpnStatus == .connected }
    }

    @Test("resources reach the store")
    func resourcesReachTheStore() async throws {
      let app = try await signedOut()
      app.tunnel.resources = [Self.engineeringWiki]

      try await app.store.signIn(token: Self.token)

      try await waitUntil { app.store.resourceList.asArray() == [Self.engineeringWiki] }
    }

    @Test("connected devices reach the store")
    func connectedDevicesReachTheStore() async throws {
      let app = try await signedOut()
      app.tunnel.resources = [Self.engineeringWiki]
      app.tunnel.connectedDevices = [Self.benchController]

      try await app.store.signIn(token: Self.token)

      try await waitUntil { app.store.connectedDevices == [Self.benchController] }
    }

    @Test("the actor and account the portal names reach the store")
    func actorAndAccountReachTheStore() async throws {
      let app = try await signedOut()
      app.tunnel.actorName = "Jane Doe"
      app.tunnel.accountSlug = "acme-corp"

      try await app.store.signIn(token: Self.token)

      try await waitUntil { app.store.actorName == "Jane Doe" }
      #expect(app.store.sessionHeading == "Signed in as Jane Doe")
      #expect(app.store.configuration.accountSlug == "acme-corp")
    }

    @Test("a resource update after the session is up reaches the store")
    func aLaterResourceUpdateReachesTheStore() async throws {
      let app = try await signedOut()
      app.tunnel.resources = []
      try await app.store.signIn(token: Self.token)
      try await waitUntil {
        if case .loaded = app.store.resourceList { return true }
        return false
      }

      app.tunnel.resources = [Self.engineeringWiki]

      try await waitUntil { app.store.resourceList.asArray() == [Self.engineeringWiki] }
    }

    @Test("enabling the Internet Resource reaches the tunnel")
    func enablingTheInternetResourceReachesTheTunnel() async throws {
      let app = try await signedOut()
      try await app.store.signIn(token: Self.token)
      try await waitUntil { app.store.vpnStatus == .connected }
      // The setting is process-wide, so leave it the way the next test expects it.
      defer { app.store.configuration.internetResourceEnabled = false }

      app.store.configuration.internetResourceEnabled = true

      try await waitUntil {
        app.tunnel.messages.contains {
          if case .setInternetResourceEnabled(true) = $0 { return true }
          return false
        }
      }
    }

    @Test("an unreachable resource is reported by name")
    func anUnreachableResourceIsReported() async throws {
      let app = try await signedOut()
      app.tunnel.resources = [Self.engineeringWiki]
      try await app.store.signIn(token: Self.token)
      try await waitUntil { app.store.resourceList.asArray() == [Self.engineeringWiki] }

      app.tunnel.notifications = [
        UnreachableResource(resourceId: Self.engineeringWiki.id, reason: .offline)
      ]

      try await waitUntil {
        app.notifications.shown.contains {
          if case .resource(let title, _) = $0 {
            return title == "Failed to connect to 'Engineering wiki'"
          }
          return false
        }
      }
    }

    @Test("a disconnect says why and clears the session")
    func aDisconnectSaysWhyAndClearsTheSession() async throws {
      let app = try await signedOut()
      app.tunnel.resources = [Self.engineeringWiki]
      try await app.store.signIn(token: Self.token)
      try await waitUntil { app.store.resourceList.asArray() == [Self.engineeringWiki] }

      app.tunnel.disconnect(with: ConnlibError.disconnected("the portal hung up"))

      try await waitUntil { app.notifications.shown.contains(.disconnected("the portal hung up")) }
      #expect(app.store.vpnStatus == .disconnected)
      #expect(app.store.resourceList.asArray().isEmpty)
    }

    @Test("a disconnect that requires signing in again says so")
    func aDisconnectThatRequiresSigningInAgainSaysSo() async throws {
      let app = try await signedOut()
      try await app.store.signIn(token: Self.token)
      try await waitUntil { app.store.vpnStatus == .connected }

      app.tunnel.disconnect(with: ConnlibError.sessionExpired("your session expired"))

      try await waitUntil { app.notifications.shown.contains(.signedOut("your session expired")) }
      #expect(app.store.vpnStatus == .disconnected)
    }

    @Test("a tunnel that fails to come up reports the failure")
    func aTunnelThatFailsToComeUpReportsTheFailure() async throws {
      let app = try await signedOut()
      app.tunnel.startFailure = ConnlibError.disconnected("connlib failed to start")

      try await app.store.signIn(token: Self.token)

      try await waitUntil {
        app.notifications.shown.contains(.disconnected("connlib failed to start"))
      }
      #expect(app.store.vpnStatus == .disconnected)
    }

    @Test("signing out tells the tunnel and stops it without an alert")
    func signingOutTellsTheTunnelAndStopsIt() async throws {
      let app = try await signedOut()
      try await app.store.signIn(token: Self.token)
      try await waitUntil { app.store.vpnStatus == .connected }

      try await app.store.signOut()

      let toldTheTunnel = app.tunnel.messages.contains {
        if case .signOut = $0 { return true }
        return false
      }
      #expect(toldTheTunnel)
      try await waitUntil { app.store.vpnStatus == .disconnected }
      #expect(app.notifications.shown.isEmpty)
    }

    private struct App {
      let store: Store
      let tunnel: MockTunnelSession
      let notifications: MockSessionNotification
    }

    /// The app as a signed-out user finds it: started, with a VPN configuration and an
    /// installed extension, and nothing running.
    private func signedOut() async throws -> App {
      let store = Store.mock(scenario: .named("welcome"))
      await store.start()

      return App(
        store: store,
        tunnel: try #require(try store.manager().session() as? MockTunnelSession),
        notifications: try #require(store.sessionNotification as? MockSessionNotification)
      )
    }
  }
#endif
