//
//  SettingsView.swift
//  (c) 2023 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Combine
import Dependencies
import SwiftUI
import XCTestDynamicOverlay

public final class SettingsViewModel: ObservableObject {
  @Dependency(\.authStore) private var authStore

  @Published var settings: Settings

  public var onSettingsSaved: () -> Void = unimplemented()
  private var cancellables = Set<AnyCancellable>()

  public init() {
    settings = Settings()
    load()
  }

  func load() {
    Task {
      authStore.tunnelStore.$tunnelAuthStatus
        .filter { $0.isInitialized }
        .receive(on: RunLoop.main)
        .sink { [weak self] tunnelAuthStatus in
          guard let self = self else { return }
          self.settings = Settings(accountId: tunnelAuthStatus.accountId() ?? "")
        }
        .store(in: &cancellables)
    }
  }

  func save() {
    Task {
      let accountId = await authStore.loginStatus.accountId
      if accountId == settings.accountId {
        // Not changed
        return
      }
      let tunnelAuthStatus: TunnelAuthStatus = await {
        if settings.accountId.isEmpty {
          return .accountNotSetup
        } else {
          return await authStore.tunnelAuthStatusForAccount(accountId: settings.accountId)
        }
      }()
      try await authStore.tunnelStore.setAuthStatus(tunnelAuthStatus)
      onSettingsSaved()
    }
  }
}

public struct SettingsView: View {
  @ObservedObject var model: SettingsViewModel
  @Environment(\.dismiss) var dismiss

  let teamIdAllowedCharacterSet: CharacterSet
  @State private var isExportingLogs = false

  public init(model: SettingsViewModel) {
    self.model = model
    self.teamIdAllowedCharacterSet = {
      var pathAllowed = CharacterSet.urlPathAllowed
      pathAllowed.remove("/")
      return pathAllowed
    }()
  }

  public var body: some View {
    #if os(iOS)
      ios
    #elseif os(macOS)
      mac
    #else
      #error("Unsupported platform")
    #endif
  }

  #if os(iOS)
    private var ios: some View {
      NavigationView() {
        VStack(spacing: 10) {
          form
          ExportLogsButton(isProcessing: $isExportingLogs) {
            self.exportLogsButtonTapped()
          }
          Spacer()
        }
        .toolbar {
          ToolbarItem(placement: .navigationBarTrailing) {
            Button("Save") {
              self.saveButtonTapped()
            }
            .disabled(!isTeamIdValid(model.settings.accountId))
          }
          ToolbarItem(placement: .navigationBarLeading) {
            Button("Cancel") {
              self.cancelButtonTapped()
            }
          }
        }
      }
    }
  #endif

  #if os(macOS)
    private var mac: some View {
      VStack(spacing: 50) {
        form
        HStack(spacing: 30) {
          Button(
            "Cancel",
            action: {
              self.cancelButtonTapped()
            })
          Button(
            "Save",
            action: {
              self.saveButtonTapped()
            }
          )
          .disabled(!isTeamIdValid(model.settings.accountId))
        }
        ExportLogsButton(isProcessing: $isExportingLogs) {
          self.exportLogsButtonTapped()
        }
      }
    }
  #endif

  private var form: some View {
    Form {
      Section {
        FormTextField(
          title: "Account ID:",
          baseURLString: AppInfoPlistConstants.authBaseURL.absoluteString,
          placeholder: "account-id",
          text: Binding(
            get: { model.settings.accountId },
            set: { model.settings.accountId = $0 }
          )
        )
      }
    }
    .navigationTitle("Settings")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
      }
    }
  }

  private func isTeamIdValid(_ teamId: String) -> Bool {
    !teamId.isEmpty && teamId.unicodeScalars.allSatisfy { teamIdAllowedCharacterSet.contains($0) }
  }

  func saveButtonTapped() {
    model.save()
    dismiss()
  }

  func cancelButtonTapped() {
    model.load()
    dismiss()
  }

  func exportLogsButtonTapped() {
    self.isExportingLogs = true
    Task {
      try await Task.sleep(nanoseconds: 2_000_000_000)
      self.isExportingLogs = false
    }
  }
}

struct ExportLogsButton: View {
  @Binding var isProcessing: Bool
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Label(
        title: { Text("Export Logs") },
        icon: {
          if isProcessing {
            ProgressView().controlSize(.small)
              .frame(minWidth: 12)
          } else {
            Image(systemName: "arrow.up.doc")
              .frame(minWidth: 12)
          }
        })
      .labelStyle(.titleAndIcon)
    }
    .disabled(isProcessing)
  }
}

struct FormTextField: View {
  let title: String
  let baseURLString: String
  let placeholder: String
  let text: Binding<String>

  var body: some View {
    #if os(iOS)
      HStack(spacing: 15) {
        Text(title)
        Spacer()
        TextField(baseURLString, text: text, prompt: Text(placeholder))
          .autocorrectionDisabled()
          .multilineTextAlignment(.leading)
          .foregroundColor(.secondary)
          .frame(maxWidth: .infinity)
          .textInputAutocapitalization(.never)
      }
    #else
      HStack(spacing: 30) {
        Spacer()
        VStack(alignment: .leading) {
          Label(title, image: "")
            .labelStyle(.titleOnly)
            .multilineTextAlignment(.leading)
          TextField(baseURLString, text: text, prompt: Text(placeholder))
            .autocorrectionDisabled()
            .multilineTextAlignment(.leading)
            .foregroundColor(.secondary)
            .frame(maxWidth: 360)
        }
        Spacer()
      }
    #endif
  }
}

struct SettingsView_Previews: PreviewProvider {
  static var previews: some View {
    SettingsView(model: SettingsViewModel())
  }
}
