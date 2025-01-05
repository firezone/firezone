//
//  iOSNavigationView.swift
//
//
//  Created by Jamil Bou Kheir on 5/25/24.
//
//  A View that contains common elements, intended to be inherited from.

import SwiftUI

#if os(iOS)
struct iOSNavigationView<Content: View>: View {
  @State private var isSettingsPresented = false
  @ObservedObject var model: AppViewModel
  @Environment(\.openURL) var openURL

  let content: Content

  init(model: AppViewModel, @ViewBuilder content: () -> Content) {
    self.model = model
    self.content = content()
  }

  var body: some View {
    NavigationView {
      content
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarItems(leading: AuthMenu)
        .navigationBarItems(trailing: SettingsButton)
    }
    .sheet(isPresented: $isSettingsPresented) {
      SettingsView(favorites: model.favorites, model: SettingsViewModel(store: model.store))
    }
    .navigationViewStyle(StackNavigationViewStyle())
  }

  private var SettingsButton: some View {
    Button(action: {
      isSettingsPresented = true
    }) {
      Label("Settings", systemImage: "gear")
    }
    .disabled(model.status == .invalid)
  }

  private var AuthMenu: some View {
    Menu {
      if model.status == .connected {
        Text("Signed in as \(model.store.actorName ?? "Unknown user")")
        Button(action: {
          signOutButtonTapped()
        }) {
          Label("Sign out", systemImage: "rectangle.portrait.and.arrow.right")
        }
      } else {
        Button(action: {
          WebAuthSession.signIn(store: model.store)
        }) {
          Label("Sign in", systemImage: "person.crop.circle.fill.badge.plus")
        }
      }
      Divider()
      Button(action: {
        openURL(URL(string: "https://www.firezone.dev/support?utm_source=ios-client")!)
      }) {
        Label("Support...", systemImage: "safari")
      }
      Button(action: {
        openURL(URL(string: "https://www.firezone.dev/kb?utm_source=ios=client")!)
      }) {
        Label("Documentation...", systemImage: "safari")
      }
    } label: {
      Image(systemName: "person.circle")
    }
  }

  private func signOutButtonTapped() {
    Task {
      try await model.store.signOut()
    }
  }
}
#endif
