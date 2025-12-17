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
      NavigationView {
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
      .navigationViewStyle(StackNavigationViewStyle())
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
          Text("Signed in as \(store.actorName)")
          Button(
            action: {
              signOutButtonTapped()
            },
            label: {
              Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
            }
          )
        } else {
          Button(
            action: {
              signInButtonTapped()

            },
            label: {
              Label("Sign in", systemImage: "person.crop.circle.fill.badge.plus")
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

    func signOutButtonTapped() {
      Task {
        do {
          try await store.signOut()
        } catch {
          Log.error(error)

          self.errorHandler.handle(
            ErrorAlert(
              title: "Error signing out",
              error: error
            )
          )
        }
      }
    }

    private func supportButtonTapped() {
      // defaultSupportURL is a static constant guaranteed to be valid
      let url =
        URL(string: configuration.supportURL)
        ?? URL(string: Configuration.defaultSupportURL)!  // swiftlint:disable:this force_unwrapping
      openURL(url)
    }
  }
#endif
