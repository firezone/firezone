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
    settings = Settings(portalURL: nil)

    if let storedSettings = settingsClient.fetchSettings() {
      settings = storedSettings
    }
  }

  func saveButtonTapped() {
    settingsClient.saveSettings(settings)
    onSettingsSaved()
  }
}

public struct SettingsView: View {
  @ObservedObject var model: SettingsViewModel

  public init(model: SettingsViewModel) {
    self.model = model
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
      form
    }
  #endif

  private var form: some View {
    Form {
      Section {
        FormTextField(
          title: "Portal URL",
          placeholder: "http://localhost:4567",
          text: Binding(
            get: { model.settings.portalURL?.absoluteString ?? "" },
            set: { model.settings.portalURL = URL(string: $0) }
          )
        )
      }
    }
    .navigationTitle("Settings")
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button("Save") {
          model.saveButtonTapped()
        }
      }
    }
  }
}

struct FormTextField: View {
  let title: String
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
      TextField(title, text: text, prompt: Text(placeholder))
        .autocorrectionDisabled()
        .multilineTextAlignment(.trailing)
        .foregroundColor(.secondary)
    #endif
  }
}

struct SettingsView_Previews: PreviewProvider {
  static var previews: some View {
    SettingsView(model: SettingsViewModel())
  }
}
