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
                message: Text(alert.error.localizedDescription),
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
          Text(store.sessionHeading)
          Button(
            action: {
              endSession()
            },
            label: {
              Label(endSessionTitle, systemImage: "rectangle.portrait.and.arrow.right")
            }
          )
        } else {
          Button(
            action: {
              startSession()
            },
            label: {
              Label(startSessionTitle, systemImage: "person.crop.circle.fill.badge.plus")
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

    /// What the control that starts a session reads, given who the certificate names.
    private var startSessionTitle: String {
      switch store.certificateIdentity {
      case .absent: return "Sign in"
      case .claimed(.some(let email)): return "Connect as \(email)"
      case .claimed(.none): return "Connect"
      }
    }

    /// A session a certificate started is disconnected from rather than signed out of.
    private var endSessionTitle: String {
      switch store.certificateIdentity {
      case .absent: return "Sign out"
      case .claimed: return "Disconnect"
      }
    }

    func startSession() {
      switch store.certificateIdentity {
      case .absent:
        signInButtonTapped()
      case .claimed:
        connectButtonTapped()
      }
    }

    func signInButtonTapped() {
      Task {
        do {
          try await WebAuthSession.signIn(store: store)
        } catch {
          Log.error(error)

          self.errorHandler.handle(
            ErrorAlert(
              title: "Error signing in",
              error: error
            )
          )
        }
      }
    }

    func connectButtonTapped() {
      Task {
        do {
          try await store.connectWithCertificate()
        } catch {
          Log.error(error)

          self.errorHandler.handle(
            ErrorAlert(
              title: "Error connecting",
              error: error
            )
          )
        }
      }
    }

    func endSession() {
      Task {
        do {
          try await store.endSession()
        } catch {
          Log.error(error)

          self.errorHandler.handle(
            ErrorAlert(
              title: "Error ending session",
              error: error
            )
          )
        }
      }
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
