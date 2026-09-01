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
        Text(welcomeText)
          .multilineTextAlignment(.center)
          .padding(.bottom, 10)
        Button(startSessionTitle) {
          startSession()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        Spacer()
      }
    )
  }

  /// What the text above the control says, given whether a certificate claims an identity.
  private var welcomeText: String {
    switch store.certificateIdentity {
    case .absent:
      return """
        Welcome to Firezone.
        Sign in to access Resources.
        """
    case .claimed:
      return """
        Welcome to Firezone.
        This device has a certificate that identifies you.
        """
    }
  }

  /// What the control that starts a session reads, given who the certificate names.
  private var startSessionTitle: String {
    switch store.certificateIdentity {
    case .absent: return "Sign in"
    case .claimed(.some(let email)): return "Connect as \(email)"
    case .claimed(.none): return "Connect"
    }
  }

  private func startSession() {
    switch store.certificateIdentity {
    case .absent:
      signIn()
    case .claimed:
      connect()
    }
  }

  private func signIn() {
    Task {
      do {
        try await WebAuthSession.signIn(store: store)
      } catch {
        Log.error(error)

        self.errorHandler.handle(ErrorAlert(title: "Error signing in", error: error))
      }
    }
  }

  private func connect() {
    Task {
      do {
        try await store.connectWithCertificate()
      } catch {
        Log.error(error)

        self.errorHandler.handle(ErrorAlert(title: "Error connecting", error: error))
      }
    }
  }
}
