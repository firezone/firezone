//
//  MenuBarView.swift
//  (c) 2025 Firezone, Inc.
//  LICENSE: Apache-2.0
//

#if os(macOS)
  import NetworkExtension
  import SwiftUI

  /// Main content view for MenuBarExtra
  @MainActor
  public struct MenuBarView: View {
    @EnvironmentObject var store: Store

    public init() {}

    public var body: some View {
      // Sign in/out section
      SignInSection()

      Divider()

      // Resources (only when connected and not hidden by admin)
      if store.vpnStatus == .connected && !store.configuration.publishedHideResourceList {
        ResourcesSection()
        Divider()
      }

      // System menu items
      SystemMenuSection()

      Divider()

      // Update notification (conditional)
      if store.updateChecker.updateAvailable {
        UpdateMenuItem()
        Divider()
      }

      // Quit
      QuitMenuItem()
    }
  }

  /// Sign in/out section with status-based rendering
  struct SignInSection: View {
    @EnvironmentObject var store: Store

    var body: some View {
      switch store.vpnStatus {
      case nil:
        Text("Loading VPN configurations from system settings…")
          .foregroundStyle(.secondary)

      case .invalid:
        Button("Allow the VPN permission to sign in…") {
          grantPermission()
        }

      case .disconnected:
        Button("Sign In") {
          signIn()
        }

      case .disconnecting:
        Text("Signing out…")
          .foregroundStyle(.secondary)

      case .connected, .reasserting, .connecting:
        Group {
          Text("Signed in as \(store.actorName)")
            .foregroundStyle(.secondary)

          Button("Sign Out") {
            signOut()
          }
        }

      @unknown default:
        Text("Unknown status")
          .foregroundStyle(.secondary)
      }
    }

    func signIn() {
      Task {
        do {
          try await WebAuthSession.signIn(store: store)
        } catch {
          Log.error(error)
          MacOSAlert.show(for: error)
        }
      }
    }

    func signOut() {
      Task {
        do {
          try await store.signOut()
        } catch {
          Log.error(error)
          MacOSAlert.show(for: error)
        }
      }
    }

    func grantPermission() {
      Task {
        do {
          try await store.systemExtensionRequest(.install)
          try await store.installVPNConfiguration()
        } catch let error as NSError {
          if error.domain == "NEVPNErrorDomain" && error.code == 5 {
            // User didn't click "Allow"
            let alert = NSAlert()
            alert.messageText =
              "Firezone requires permission to install VPN configurations. Without it, all functionality will be disabled."
            _ = alert.runModal()
          } else {
            Log.error(error)
            MacOSAlert.show(for: error)
          }
        } catch {
          Log.error(error)
          MacOSAlert.show(for: error)
        }
      }
    }
  }

  /// System menu section (About, Admin Portal, Help, Settings)
  struct SystemMenuSection: View {
    @EnvironmentObject var store: Store

    var body: some View {
      Button("About Firezone") {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
      }

      if !store.configuration.publishedHideAdminPortalMenuItem {
        Button("Admin Portal…") {
          openAdminPortal()
        }
      }

      Menu("Help") {
        Button("Documentation…") {
          openDocumentation()
        }

        Button("Support…") {
          openSupport()
        }
      }

      Button("Settings") {
        AppView.WindowDefinition.settings.openWindow()
      }
    }

    func openAdminPortal() {
      guard let baseURL = URL(string: store.configuration.authURL) else {
        Log.warning("Admin portal URL invalid: \(store.configuration.authURL)")
        let alert = NSAlert()
        alert.messageText = "Cannot Open Admin Portal"
        alert.informativeText =
          "The admin portal URL appears to be invalid. Please contact your administrator."
        alert.alertStyle = .warning
        _ = alert.runModal()
        return
      }

      let accountSlug = store.configuration.accountSlug
      let authURL = baseURL.appendingPathComponent(accountSlug)

      Task { await NSWorkspace.shared.openAsync(authURL) }
    }

    func openDocumentation() {
      guard let url = URL(string: "https://www.firezone.dev/kb?utm_source=macos-client")
      else { return }
      Task { await NSWorkspace.shared.openAsync(url) }
    }

    func openSupport() {
      guard
        let url = URL(string: store.configuration.supportURL)
          ?? URL(string: Configuration.defaultSupportURL)
      else { return }
      Task { await NSWorkspace.shared.openAsync(url) }
    }
  }

  /// Update notification menu item
  struct UpdateMenuItem: View {
    var body: some View {
      Button("Update available…") {
        Task {
          await NSWorkspace.shared.openAsync(UpdateChecker.downloadURL())
        }
      }
    }
  }

  /// Quit menu item with dynamic title
  struct QuitMenuItem: View {
    @EnvironmentObject var store: Store

    var body: some View {
      Button(quitTitle) {
        NSApp.terminate(nil)
      }
    }

    var quitTitle: String {
      switch store.vpnStatus {
      case .connected, .connecting:
        return "Disconnect and Quit"
      default:
        return "Quit"
      }
    }
  }
#endif
