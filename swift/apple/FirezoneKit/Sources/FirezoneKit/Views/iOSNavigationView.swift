//
//  IOSNavigationView.swift
//
//
//  Created by Jamil Bou Kheir on 5/25/24.
//
//  A View that contains common elements, intended to be inherited from.

import SwiftUI

#if os(iOS)
  struct IOSNavigationView<Content: View>: View {
    @State private var isSettingsPresented = false
    @EnvironmentObject var store: Store
    @Environment(\.openURL) var openURL
    @EnvironmentObject var errorHandler: GlobalErrorHandler

    let content: Content

    private let configuration = Configuration.shared

    init(@ViewBuilder content: () -> Content) {
      self.content = content()
    }

    var body: some View {
      NavigationStack {
        content
          .navigationBarTitleDisplayMode(.inline)
          .navigationBarItems(leading: authMenu, trailing: settingsButton)
          .alert(
            item: $errorHandler.currentAlert,
            content: { alert in
              Alert(
                title: Text(alert.title),
                message: Text(alert.message ?? alert.error.localizedDescription),
                dismissButton: .default(Text("OK")) {
                  errorHandler.clear()
                }
              )
            }
          )
      }
      .sheet(isPresented: $isSettingsPresented) {
        SettingsView(store: store)
      }
    }

    private var settingsButton: some View {
      Button(
        action: {
          isSettingsPresented = true
        },
        label: {
          Label("Settings", systemImage: "gear")
        }
      )
      .disabled(store.vpnStatus == .invalid)
    }

    private var authMenu: some View {
      Menu {
        if store.vpnStatus == .connected {
          Text(
            store.certificateUserIdentity == nil
              ? "Signed in as \(store.actorName)"
              : "Connected as \(store.actorName)"
          )
          Button(
            action: {
              signOutButtonTapped()
            },
            label: {
              Label(
                store.certificateUserIdentity == nil ? "Sign out" : "Disconnect",
                systemImage: "rectangle.portrait.and.arrow.right"
              )
            }
          )
        } else {
          Button(
            action: {
              signInButtonTapped()

            },
            label: {
              Label(
                store.certificateUserIdentity.map { "Connect as \($0.email)" } ?? "Sign in",
                systemImage: "person.crop.circle.fill.badge.plus"
              )
            }
          )
        }
        Divider()
        Button(
          action: {
            supportButtonTapped()
          },
          label: {
            Label("Support...", systemImage: "safari")
          }
        )
        Button(
          action: {
            // Static URL literal is guaranteed valid
            // swiftlint:disable:next force_unwrapping
            openURL(URL(string: "https://www.firezone.dev/kb?utm_source=ios=client")!)
          },
          label: {
            Label("Documentation...", systemImage: "safari")
          }
        )
      } label: {
        Image(systemName: "person.circle")
      }
    }

    func signInButtonTapped() {
      Task {
        do {
          try await store.connect()
        } catch {
          Log.error(error)

          self.errorHandler.handle(
            ErrorAlert(
              title: store.authenticationMode == .x509 ? "Unable to connect" : "Error signing in",
              error: error,
              message: authenticationErrorMessage(error)
            )
          )
        }
      }
    }

    func signOutButtonTapped() {
      Task {
        do {
          try await store.disconnect()
        } catch {
          Log.error(error)

          self.errorHandler.handle(
            ErrorAlert(
              title: store.authenticationMode == .x509
                ? "Unable to disconnect" : "Error signing out",
              error: error,
              message: authenticationErrorMessage(error)
            )
          )
        }
      }
    }

    private func authenticationErrorMessage(_ error: Error) -> String? {
      guard store.authenticationMode == .x509 else { return nil }
      return SessionAuthenticationMode.x509.failureMessage(error.localizedDescription)
    }

    private func supportButtonTapped() {
      guard let defaultURL = URL(string: ConfigurationDefaults.supportURL) else { return }

      let url =
        URL(string: configuration.supportURL)
        ?? defaultURL
      openURL(url)
    }
  }
#endif
