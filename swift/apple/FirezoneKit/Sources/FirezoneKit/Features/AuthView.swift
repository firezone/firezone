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

  @Published var buttonTitle = "Sign In"

  func signInButtonTapped() async {
    guard let accountId = authStore.tunnelStore.tunnelAuthStatus.accountId(),
      !accountId.isEmpty
    else {
      settingsUndefined()
      return
    }

    do {
      try await authStore.signIn(accountId: accountId)
    } catch {
      dump(error)
    }
  }
}

struct AuthView: View {
  @ObservedObject var model: AuthViewModel

  var body: some View {
    VStack {
      Text("Welcome to Firezone").font(.largeTitle)

      Button(self.model.buttonTitle) {
        Task {
          await model.signInButtonTapped()
        }
      }
      .buttonStyle(.borderedProminent)
    }
  }
}

struct AuthView_Previews: PreviewProvider {
  static var previews: some View {
    AuthView(model: AuthViewModel())
  }
}
