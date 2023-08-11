//
//  SettingsView.swift
//  (c) 2023 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Dependencies
import SwiftUI
import XCTestDynamicOverlay

public final class SettingsViewModel: ObservableObject {
  @Dependency(\.settingsClient) private var settingsClient

  @Published var settings: Settings

  public var onSettingsSaved: () -> Void = unimplemented()

  public init() {
    settings = Settings()

    load()
  }

  func load() {
    if let storedSettings = settingsClient.fetchSettings() {
      settings = storedSettings
    }
  }

  func save() {
    settingsClient.saveSettings(settings)
    onSettingsSaved()
  }
}

public struct SettingsView: View {
  @ObservedObject var model: SettingsViewModel
  @Environment(\.dismiss) var dismiss

  let teamIdAllowedCharacterSet: CharacterSet

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
      NavigationView {
        form
      }
    }
  #endif

  #if os(macOS)
    private var mac: some View {
      VStack(spacing: 50) {
        form
        HStack(spacing: 30) {
          Button("Cancel", action: {
            self.cancelButtonTapped()
          })
          Button("Save", action: {
            self.saveButtonTapped()
          })
          .disabled(!isTeamIdValid(model.settings.teamId))
        }
      }
    }
  #endif

  private var form: some View {
    Form {
      Section {
        FormTextField(
          title: "Team URL:",
          baseURLString: AuthStore.getAuthBaseURLFromInfoPlist().absoluteString,
          placeholder: "team-id",
          text: Binding(
            get: { model.settings.teamId },
            set: { model.settings.teamId = $0 }
          )
        )
      }
    }
    .navigationTitle("Settings - Firezone")
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
}

struct FormTextField: View {
  let title: String
  let baseURLString: String
  let placeholder: String
  let text: Binding<String>

  var body: some View {
    #if os(iOS)
      HStack {
        Text(title)
        Spacer()
        TextField(placeholder, text: text)
          .autocorrectionDisabled()
          .multilineTextAlignment(.trailing)
          .foregroundColor(.secondary)
          .frame(maxWidth: .infinity)
          .textInputAutocapitalization(.never)
          .textContentType(.URL)
          .keyboardType(.URL)
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
