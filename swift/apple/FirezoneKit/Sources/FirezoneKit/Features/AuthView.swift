//
//  AuthView.swift
//  (c) 2023 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import AuthenticationServices
import Combine
import Dependencies
import JWTDecode
import SwiftUI
import XCTestDynamicOverlay

@MainActor
final class AuthViewModel: ObservableObject {
  @Dependency(\.settingsClient) private var settingsClient
  @Dependency(\.authStore) private var authStore

  var settingsUndefined: () -> Void = unimplemented("\(AuthViewModel.self).settingsUndefined")

  private var cancellables = Set<AnyCancellable>()

  func logInButtonTapped() async {
    guard let portalURL = settingsClient.fetchSettings()?.portalURL else {
      settingsUndefined()
      return
    }

    do {
      try await authStore.signIn(portalURL: portalURL)
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

      Button("Log in") {
        Task {
          await model.logInButtonTapped()
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
