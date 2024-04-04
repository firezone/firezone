//
//  GrantNotificationsView.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Combine
import Foundation
import SwiftUI

@MainActor
public final class GrantNotificationsViewModel: ObservableObject {
  private var store: Store

  init(store: Store) {
    self.store = store
  }

  func grantNotificationButtonTapped() {
    store.requestNotifications()
  }
}

struct GrantNotificationsView: View {
  @ObservedObject var model: GrantNotificationsViewModel

  public var body: some View {
    VStack(
      alignment: .center,
      content: {
        Spacer()
        Image("LogoText")
          .resizable()
          .scaledToFit()
          .frame(maxWidth: 320)
          .padding(.horizontal, 10)
        Spacer()
        Text(
          "Firezone requires your permission to show local notifications when you need to sign in again."
        )
        .font(.body)
        .multilineTextAlignment(.center)
        .padding(EdgeInsets(top: 0, leading: 5, bottom: 0, trailing: 5))
        Spacer()
        Image(systemName: "bell")
          .imageScale(.large)
        Spacer()
        Button("Grant Notification Permission") {
          model.grantNotificationButtonTapped()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        Spacer()
          .frame(maxHeight: 20)
        Text(
          "After tapping the above button, tap 'Allow' when prompted."
        )
        .font(.caption)
        .multilineTextAlignment(.center)
        Spacer()
      })
  }
}
