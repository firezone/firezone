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
        Text(
          store.authenticationMode == .x509
            ? "Welcome to Firezone.\nConnect to access Resources."
            : "Welcome to Firezone.\nSign in to access Resources."
        ).multilineTextAlignment(.center)
          .padding(.bottom, 10)
        Button(
          store.certificateUserIdentity.map { "Connect as \($0.email)" } ?? "Sign in"
        ) {
          Task {
            do {
              try await store.connect()
            } catch {
              Log.error(error)

              self.errorHandler.handle(
                ErrorAlert(
                  title: store.authenticationMode == .x509
                    ? "Unable to connect" : "Error signing in",
                  error: error,
                  message:
                    store.authenticationMode == .x509
                    ? SessionAuthenticationMode.x509.failureMessage(error.localizedDescription)
                    : nil
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
