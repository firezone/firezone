//
//  AuthView.swift
//  (c) 2023 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import AuthenticationServices
import Combine
import Dependencies
import SwiftUI
import XCTestDynamicOverlay

@MainActor
final class AuthViewModel: ObservableObject {
  @Dependency(\.authStore) private var authStore

  var settingsUndefined: () -> Void = unimplemented("\(AuthViewModel.self).settingsUndefined")

  private var cancellables = Set<AnyCancellable>()

  func signInButtonTapped() async {
    do {
      try await authStore.signIn()
    } catch {
      dump(error)
    }
  }
}

struct AuthView: View {
  @ObservedObject var model: AuthViewModel

  var body: some View {
    VStack(
      alignment: .center,
      content: {
        Spacer()
        Image("LogoText")
        Spacer()
        Button("Sign in") {
          Task {
            await model.signInButtonTapped()
          }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
      })
  }
}

struct AuthView_Previews: PreviewProvider {
  static var previews: some View {
    AuthView(model: AuthViewModel())
  }
}
