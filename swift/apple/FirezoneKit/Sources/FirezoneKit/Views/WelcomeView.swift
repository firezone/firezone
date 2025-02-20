//
//  WelcomeView.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import AuthenticationServices
import Combine
import SwiftUI

struct WelcomeView: View {
  @EnvironmentObject var errorHandler: GlobalErrorHandler
  @EnvironmentObject var store: Store

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
          Task {
            do {
              try await WebAuthSession.signIn(store: store)
            } catch {
              Log.error(error)

              self.errorHandler.handle(ErrorAlert(
                title: "Error signing in",
                error: error
              ))
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
