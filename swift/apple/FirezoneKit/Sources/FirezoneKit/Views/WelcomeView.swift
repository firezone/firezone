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
          """
            Welcome to Firezone.
            Sign in to access Resources.
          """
        ).multilineTextAlignment(.center)
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

  /// What the control that starts a session reads, given who the certificate names.
  private var startSessionTitle: String {
    switch store.certificateIdentity {
    case .absent: return "Sign in"
    case .resolved(_, .email(let email)): return "Connect as \(email)"
    case .resolved(_, .id), .refused: return "Connect"
    }
  }

  private func startSession() {
    switch store.certificateIdentity {
    case .absent:
      signIn()
    case .resolved:
      connect()
    case .refused:
      self.errorHandler.handle(
        ErrorAlert(title: "Cannot connect", error: X509ConnectError.refusedIdentity))
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
