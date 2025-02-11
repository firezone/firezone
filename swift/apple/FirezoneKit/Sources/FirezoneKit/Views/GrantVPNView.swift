//
//  GrantVPNView.swift
//
//
//  Created by Jamil Bou Kheir on 4/2/24.
//

import SwiftUI
import Combine

@MainActor
final class GrantVPNViewModel: ObservableObject {
  @Published var isInstalled: Bool = false

  private let store: Store
  private var cancellables: Set<AnyCancellable> = []

  init(store: Store) {
    self.store = store

#if os(macOS)
    store.$systemExtensionStatus
      .receive(on: DispatchQueue.main)
      .sink(receiveValue: { [weak self] status in
        self?.isInstalled = status == .installed
      }).store(in: &cancellables)
#endif
  }

#if os(macOS)
  func installSystemExtensionButtonTapped() {
    Task {
      do {
        try await store.installSystemExtension()

        // The window has a tendency to go to the background after installing
        // the system extension
        NSApp.activate(ignoringOtherApps: true)

      } catch {
        Log.error(error)
        await macOSAlert.show(for: error)
      }
    }
  }

  func grantPermissionButtonTapped() {
    Log.log("\(#function)")
    Task {
      do {
        try await store.grantVPNPermission()

        // The window has a tendency to go to the background after allowing the
        // VPN configuration
        NSApp.activate(ignoringOtherApps: true)
      } catch {
        Log.error(error)
        await macOSAlert.show(for: error)
      }
    }
  }
#endif

#if os(iOS)
  func grantPermissionButtonTapped(errorHandler: GlobalErrorHandler) {
    Log.log("\(#function)")
    Task {
      do {
        try await store.grantVPNPermission()
      } catch {
        Log.error(error)

        errorHandler.handle(
          ErrorAlert(
            title: "Error installing VPN configuration",
            error: error
          )
        )
      }
    }
  }
#endif
}

struct GrantVPNView: View {
  @ObservedObject var model: GrantVPNViewModel
  @EnvironmentObject var errorHandler: GlobalErrorHandler

  var body: some View {
#if os(iOS)
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
        Text("""
        Firezone requires your permission to create VPN configurations.
        Until it has that permission, all functionality will be disabled.
        """)
        .font(.body)
        .multilineTextAlignment(.center)
        .padding(EdgeInsets(top: 0, leading: 5, bottom: 0, trailing: 5))
        Spacer()
        Image(systemName: "network.badge.shield.half.filled")
          .imageScale(.large)
        Spacer()
        Button("Grant VPN Permission") {
          model.grantPermissionButtonTapped(errorHandler: errorHandler)
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
#elseif os(macOS)
    VStack(
      alignment: .center,
      content: {
        Spacer()
        Image("LogoText")
          .resizable()
          .scaledToFit()
          .frame(maxWidth: 200)
          .padding(.horizontal, 10)
        Spacer()
        Spacer()
        Text("""
        Firezone needs you to enable a System Extension and allow a VPN configuration in order to function.
        """)
        .font(.title2)
        .multilineTextAlignment(.center)
        .padding(EdgeInsets(top: 0, leading: 10, bottom: 0, trailing: 15))
        Spacer()
        Spacer()
        HStack(alignment: .top) {
          Spacer()
          VStack(alignment: .center) {
            Text("Step 1: Enable the system extension")
              .font(.title)
              .strikethrough(model.isInstalled, color: .primary)
            Text("""
            1. Click the "Enable System Extension" button below.
            2. Click "Open System Settings" in the dialog that appears.
            3. Ensure the FirezoneNetworkExtension is toggled ON.
            4. Click Done.
            """)
            .font(.body)
            .padding(.vertical, 10)
            .opacity(model.isInstalled ? 0.5 : 1.0)
            Spacer()
            Button(
              action: {
                model.installSystemExtensionButtonTapped()
              },
              label: {
                Label("Enable System Extension", systemImage: "gearshape")
              }
            )
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(model.isInstalled)
          }
          Spacer()
          VStack(alignment: .center) {
            Text("Step 2: Allow the VPN configuration")
              .font(.title)
            Text("""
            1. Click the "Grant VPN Permission" button below.
            2. Click "Allow" in the dialog that appears.
            """)
            .font(.body)
            .padding(.vertical, 10)
            Spacer()
            Button(
              action: {
                model.grantPermissionButtonTapped()
              },
              label: {
                Label("Grant VPN Permission", systemImage: "network.badge.shield.half.filled")
              }
            )
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!model.isInstalled)
          }.opacity(model.isInstalled ? 1.0 : 0.5)
          Spacer()
        }
        Spacer()
        Spacer()
      }
    )
    Spacer()
#endif
  }
}
