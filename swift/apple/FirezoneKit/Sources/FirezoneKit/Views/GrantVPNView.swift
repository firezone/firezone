//
//  GrantVPNView.swift
//
//
//  Created by Jamil Bou Kheir on 4/2/24.
//

import Combine
import SwiftUI

#if os(macOS)
  import SystemExtensions
#endif

struct GrantVPNView: View {
  @EnvironmentObject var store: Store
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
          Text(
            """
            Firezone requires your permission to create VPN configurations.
            Until it has that permission, all functionality will be disabled.
            """
          )
          .font(.body)
          .multilineTextAlignment(.center)
          .padding(EdgeInsets(top: 0, leading: 5, bottom: 0, trailing: 5))
          Spacer()
          Image(systemName: "network.badge.shield.half.filled")
            .imageScale(.large)
          Spacer()
          Button("Grant VPN Permission") {
            installVPNConfiguration()
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
          Text(
            """
            Firezone needs you to enable a System Extension and allow a VPN configuration in order to function.
            """
          )
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
                .strikethrough(isInstalled(), color: .primary)
              Text(
                """
                1. Click the "Enable System Extension" button below.
                2. Click "Open System Settings" in the dialog that appears.
                3. Ensure the FirezoneNetworkExtension is toggled ON.
                4. Click Done.
                """
              )
              .font(.body)
              .padding(.vertical, 10)
              .opacity(isInstalled() ? 0.5 : 1.0)
              Spacer()
              Button(
                action: {
                  installSystemExtension()
                },
                label: {
                  Label("Enable System Extension", systemImage: "gearshape")
                }
              )
              .buttonStyle(.borderedProminent)
              .controlSize(.large)
              .disabled(isInstalled())
            }
            Spacer()
            VStack(alignment: .center) {
              Text("Step 2: Allow the VPN configuration")
                .font(.title)
              Text(
                """
                1. Click the "Grant VPN Permission" button below.
                2. Click "Allow" in the dialog that appears.
                """
              )
              .font(.body)
              .padding(.vertical, 10)
              Spacer()
              Button(
                action: {
                  installVPNConfiguration()
                },
                label: {
                  Label("Grant VPN Permission", systemImage: "network.badge.shield.half.filled")
                }
              )
              .buttonStyle(.borderedProminent)
              .controlSize(.large)
              .disabled(!isInstalled())
            }.opacity(isInstalled() ? 1.0 : 0.5)
            Spacer()
          }
          Spacer()
          Spacer()
        }
      )
      Spacer()
    #endif
  }

  #if os(macOS)
    func installSystemExtension() {
      Task {
        do {
          try await store.systemExtensionRequest(.install)

          // The window has a tendency to go to the background after installing
          // the system extension
          NSApp.activate(ignoringOtherApps: true)
        } catch {
          Log.error(error)
          MacOSAlert.show(for: error)
        }
      }
    }

    func installVPNConfiguration() {
      Task {
        do {
          try await store.installVPNConfiguration()
        } catch let error as NSError {
          if error.domain == "NEVPNErrorDomain" && error.code == 5 {
            // Warn when the user doesn't click "Allow" on the VPN dialog
            let alert = NSAlert()
            alert.messageText = "Permission required."
            alert.informativeText =
              "Firezone requires permission to install VPN configurations. Without it, all functionality will be disabled."
            _ = await MacOSAlert.show(alert)
          } else {
            throw error
          }
        } catch {
          Log.error(error)
          MacOSAlert.show(for: error)
        }
      }
    }

    func isInstalled() -> Bool {
      return store.systemExtensionStatus == .installed
    }
  #endif

  #if os(iOS)
    func installVPNConfiguration() {
      Task {
        do {
          try await store.installVPNConfiguration()
        } catch {
          Log.error(error)

          errorHandler.handle(
            ErrorAlert(
              title: "Error granting VPN permission",
              error: error
            ))
        }
      }
    }
  #endif
}
