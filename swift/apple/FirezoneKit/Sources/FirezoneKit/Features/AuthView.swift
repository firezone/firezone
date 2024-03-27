//
//  AuthView.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import AuthenticationServices
import Combine
import Dependencies
import SwiftUI
import XCTestDynamicOverlay

@MainActor
final class AuthViewModel: ObservableObject {

  let tunnelStore: TunnelStore

  var settingsUndefined: () -> Void = unimplemented("\(AuthViewModel.self).settingsUndefined")

  private var cancellables = Set<AnyCancellable>()

  init(tunnelStore: TunnelStore) {
    self.tunnelStore = tunnelStore
  }

  func signInButtonTapped() async {
    do {
      try await tunnelStore.signIn()
    } catch {
      dump(error)
    }
  }
}

struct AuthView: View {
  @ObservedObject var model: AuthViewModel

  // Debounce button taps
  @State private var tapped = false

  var body: some View {
    VStack(
      alignment: .center,
      content: {
        Spacer()
        Image("LogoText")
          .resizable()
          .scaledToFit()
          .frame(maxWidth: 600)
          .padding(.horizontal, 10)
        Spacer()
        Button("Sign in") {
          if !tapped {
            tapped = true

            DispatchQueue.main.async {
              Task { await model.signInButtonTapped() }
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
              tapped = false
            }
          }
        }
        .disabled(tapped)
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        Spacer()
      })
  }
}
