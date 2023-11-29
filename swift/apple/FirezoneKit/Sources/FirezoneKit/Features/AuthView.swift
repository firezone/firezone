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
  @Dependency(\.mainQueue) private var mainQueue

  var settingsUndefined: () -> Void = unimplemented("\(AuthViewModel.self).settingsUndefined")

  private var cancellables = Set<AnyCancellable>()

  @Published var buttonTitle = "Sign In"

  private var tunnelAuthStatus: TunnelAuthStatus = .tunnelUninitialized

  init() {
    authStore.tunnelStore.$tunnelAuthStatus
      .receive(on: mainQueue)
      .sink { [weak self] tunnelAuthStatus in
        guard let self = self else { return }
        self.tunnelAuthStatus = tunnelAuthStatus
        self.buttonTitle = {
          if case .accountNotSetup = tunnelAuthStatus {
            return "Enter Account ID"
          } else {
            return "Sign In"
          }
        }()
      }
      .store(in: &cancellables)
  }

  func signInButtonTapped() async {
    switch tunnelAuthStatus {
    case .tunnelUninitialized:
      break
    case .accountNotSetup:
      settingsUndefined()
    case .signedOut(_, let accountId):
      // accountId shouldn't be empty here. Just playing safe.
      guard !accountId.isEmpty else {
        settingsUndefined()
        return
      }
      do {
        try await authStore.signIn(accountId: accountId)
      } catch {
        dump(error)
      }
    case .signedIn:
      break
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
