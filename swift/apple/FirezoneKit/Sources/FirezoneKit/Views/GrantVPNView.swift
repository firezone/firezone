//
//  GrantVPNView.swift
//
//
//  Created by Jamil Bou Kheir on 4/2/24.
//

import SwiftUI

@MainActor
final class GrantVPNViewModel: ObservableObject {
  private let store: Store

  init(store: Store) {
    self.store = store
  }

  func grantPermissionButtonTapped() {
    Log.log("\(#function)")
    Task {
      do {
        try await store.createVPNProfile()
      } catch {
        Log.error("\(#function): \(error)")
      }
    }
  }
}

struct GrantVPNView: View {
  @ObservedObject var model: GrantVPNViewModel

  var body: some View {
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
          "Firezone requires your permission to create VPN tunnels. Until it has that permission, all functionality will be disabled."
        )
        .font(.body)
        .multilineTextAlignment(.center)
        .padding(EdgeInsets(top: 0, leading: 5, bottom: 0, trailing: 5))
        Spacer()
        Image(systemName: "network.badge.shield.half.filled")
          .imageScale(.large)
        Spacer()
        Button("Grant VPN Permission") {
          model.grantPermissionButtonTapped()
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        Text(
          "After \(actionVerbage()) on the above button,\nclick on 'Allow' when prompted."
        ).font(.caption)
          .multilineTextAlignment(.center)
        Spacer()
      }
    )
  }
}
