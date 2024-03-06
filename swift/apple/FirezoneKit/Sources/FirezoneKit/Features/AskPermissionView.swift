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
  private var notificationDecisionHelper: SessionNotificationHelper

  private var cancellables: Set<AnyCancellable> = []

  @Published var needsTunnelPermission = false {
    didSet {
      #if os(macOS)
        Task {
          await MainActor.run {
            AppStore.WindowDefinition.askPermission.bringAlreadyOpenWindowFront()
          }
        }
      #endif
    }
  }

  @Published var needsNotificationDecision = false

  public init(tunnelStore: TunnelStore, notificationDecisionHelper: SessionNotificationHelper) {
    self.tunnelStore = tunnelStore
    self.notificationDecisionHelper = notificationDecisionHelper

    tunnelStore.$tunnelAuthStatus
      .filter { $0.isInitialized }
      .sink { [weak self] tunnelAuthStatus in
        guard let self = self else { return }

        Task {
          await MainActor.run {
            if case .noTunnelFound = tunnelAuthStatus {
              self.needsTunnelPermission = true
            } else {
              self.needsTunnelPermission = false
            }
          }
        }
      }
      .store(in: &cancellables)

    notificationDecisionHelper.$notificationDecision
      .filter { $0.isInitialized }
      .sink { [weak self] notificationDecision in
        guard let self = self else { return }

        Task {
          await MainActor.run {
            if case .notDetermined = notificationDecision {
              self.needsNotificationDecision = true
            } else {
              self.needsNotificationDecision = false
            }
          }
        }
      }
      .store(in: &cancellables)

  }

  func grantPermissionButtonTapped() {
    Task {
      do {
        try await self.tunnelStore.createTunnel()
      } catch {
        #if os(macOS)
          DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(500)) {
            AppStore.WindowDefinition.askPermission.bringAlreadyOpenWindowFront()
          }
        #endif
      }
    }
  }

  #if os(iOS)
    func grantNotificationButtonTapped() {
      self.notificationDecisionHelper.askUserForNotificationPermissions()
    }
  #endif

  #if os(macOS)
    func closeAskPermissionWindow() {
      AppStore.WindowDefinition.askPermission.window()?.close()
    }
  #endif
}

public struct AskPermissionView: View {
  @ObservedObject var model: AskPermissionViewModel

  public init(model: AskPermissionViewModel) {
    self.model = model
  }

  public var body: some View {
    VStack(
      alignment: .center,
      content: {
        Spacer()
        Image("LogoText")
          .resizable()
          .scaledToFit()
          .frame(maxWidth: 600)
          .padding(.horizontal, 10)
        Spacer()
        if $model.needsTunnelPermission.wrappedValue {

          #if os(macOS)
            Text(
              "Firezone requires your permission to create VPN tunnels.\nUntil it has that permission, all functionality will be disabled."
            )
            .font(.body)
            .multilineTextAlignment(.center)
          #elseif os(iOS)
            Text(
              "Firezone requires your permission to create VPN tunnels. Until it has that permission, all functionality will be disabled."
            )
            .font(.body)
            .multilineTextAlignment(.center)
            .padding(EdgeInsets(top: 0, leading: 5, bottom: 0, trailing: 5))
            Spacer()
            Image(systemName: "network.badge.shield.half.filled")
              .imageScale(.large)
          #endif
          Spacer()
          Button("Grant VPN Permission") {
            model.grantPermissionButtonTapped()
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
          Spacer()
            .frame(maxHeight: 20)
          #if os(macOS)
            Text(
              "After clicking on the above button,\nclick on 'Allow' when prompted."
            )
            .font(.caption)
            .multilineTextAlignment(.center)
          #elseif os(iOS)
            Text(
              "After tapping on the above button, tap on 'Allow' when prompted."
            )
            .font(.caption)
            .multilineTextAlignment(.center)
          #endif
        } else if $model.needsNotificationDecision.wrappedValue {
          #if os(iOS)
            Text(
              "Firezone requires your permission to show local notifications whenever you become signed out of your account."
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
              "After tapping on the above button, tap on 'Allow' when prompted."
            )
            .font(.caption)
            .multilineTextAlignment(.center)
          #endif
        } else {

          #if os(macOS)
            Text(
              "You can sign in to Firezone by clicking on the Firezone icon in the macOS menu bar.\nYou may now close this window."
            )
            .font(.body)
            .multilineTextAlignment(.center)

            Spacer()
            Button("Close this Window") {
              model.closeAskPermissionWindow()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Spacer()
              .frame(maxHeight: 20)
            Text(
              "Firezone will continue running after this window is closed.\nIt will be available from the macOS menu bar."
            )
            .font(.caption)
            .multilineTextAlignment(.center)
          #endif

        }
        Spacer()
      })
  }
}
