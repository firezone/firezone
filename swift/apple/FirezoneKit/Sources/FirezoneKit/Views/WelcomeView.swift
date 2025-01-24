//
//  WelcomeView.swift
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
}

struct WelcomeView: View {
  @EnvironmentObject var errorHandler: GlobalErrorHandler
  @ObservedObject var model: WelcomeViewModel

  var body: some View {
    VStack(
      alignment: .center,
      content: {
        Spacer()
        Image("LogoText")
          .resizable()
          .scaledToFit()
          .frame(maxWidth: 300)
          .padding(.horizontal, 10)
          .padding(.vertical, 10)
        Text("""
          Welcome to Firezone.
          Sign in to access Resources.
        """).multilineTextAlignment(.center)
          .padding(.bottom, 10)
        Button("Sign in") {
          Task.detached {
            do {
              try await WebAuthSession.signIn(store: model.store)
            } catch {
              Log.error(error)

              await MainActor.run {
                self.errorHandler.handle(ErrorAlert(
                  title: "Error signing in",
                  error: error
                ))
              }
            }
          }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        Spacer()
      }
    )
  }
}
