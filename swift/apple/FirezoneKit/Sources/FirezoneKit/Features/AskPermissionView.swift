//
//  AskPermissionView.swift
//  (c) 2023 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Combine
import Foundation
import SwiftUI

@MainActor
public final class AskPermissionViewModel: ObservableObject {
  public var tunnelStore: TunnelStore

  public init(tunnelStore: TunnelStore) {
    self.tunnelStore = tunnelStore
  }

  func grantPermissionButtonTapped() async {
    NSLog("grantPermissionButtonTapped")
  }
}

public struct AskPermissionView: View {
  private var model: AskPermissionViewModel

  public init(model: AskPermissionViewModel) {
    self.model = model
  }

  public var body: some View {
    VStack(
      alignment: .center,
      content: {
        Spacer()
        Image("LogoText")
        Spacer()
        Text(
          "Firezone requires the VPN tunnel permission. Until then, all functionality will be disabled."
        )
        Button("Grant VPN Permission") {
          Task {
            await model.grantPermissionButtonTapped()
          }
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        Spacer()
      })
  }
}
