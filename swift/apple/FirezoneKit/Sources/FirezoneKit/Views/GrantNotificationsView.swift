//
//  GrantNotificationsView.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Combine
import Foundation
import SwiftUI
import UserNotifications

struct GrantNotificationsView: View {
  @EnvironmentObject var store: Store
  @EnvironmentObject var errorHandler: GlobalErrorHandler

  public var body: some View {
    VStack(
      alignment: .center,
      spacing: 32,
      content: {
        Spacer()
        Image("LogoText")
          .resizable()
          .scaledToFit()
          .frame(maxWidth: 320)
          .padding(.horizontal, 10)
        Text(
          "Firezone requires your permission to show local notifications when you need to sign in again."
        )
        .font(.body)
        .multilineTextAlignment(.center)
        .padding(EdgeInsets(top: 0, leading: 5, bottom: 0, trailing: 5))
        Image(systemName: "bell")
          .imageScale(.large)
        VStack {
          Button("Grant Notification Permission") {
            grantNotifications()
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          Text(
            "After tapping the above button, tap 'Allow' when prompted."
          )
          .font(.caption)
          .multilineTextAlignment(.center)
        }
        Spacer()
      })
  }

  func grantNotifications() {
    Task {
      errorHandler.clear()

      do {
        try await store.grantNotifications()
      } catch {
        Log.error(error)

        errorHandler.handle(
          ErrorAlert(
            title: "Error granting notifications",
            error: error
          ))
      }
    }
  }
}
