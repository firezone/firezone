//
//  SignedOutView.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import AuthenticationServices
import Combine
import SwiftUI

@MainActor
final class WelcomeViewModel: ObservableObject {
  let store: Store

  init(store: Store) {
    self.store = store
  }

  func signInButtonTapped() {
    Task { await WebAuthSession.signIn(store: store) }
  }
}

struct WelcomeView: View {
  @ObservedObject var model: WelcomeViewModel

  // Debounce button taps
  @State private var tapped = false

  var body: some View {
      VStack(
        alignment: .center,
        content: {
          // TODO: Same screen as Windows app
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
                 model.signInButtonTapped()
              }

              DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
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
