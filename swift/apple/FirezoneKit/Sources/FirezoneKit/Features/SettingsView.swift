//
//  SettingsView.swift
//  (c) 2023 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Combine
import Dependencies
import SwiftUI
import XCTestDynamicOverlay
import OSLog
import ZIPFoundation

enum SettingsViewError: Error {
  case logFolderIsUnavailable
}

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
  private let logger = Logger.make(for: SettingsView.self)

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

#if os(macOS)
  func exportLogsButtonTapped() {
    self.isExportingLogs = true

    let savePanel = NSSavePanel()
    savePanel.prompt = "Save"
    savePanel.nameFieldLabel = "Save log zip bundle to:"
    savePanel.nameFieldStringValue = "firezone-logs.zip"

    guard let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("firezone-settings") ?? false }) else {
      self.isExportingLogs = false
      logger.log("Settings window not found. Can't show save panel.")
      return
    }

    savePanel.beginSheetModal(for: window) { response in
      guard response == .OK else {
        self.isExportingLogs = false
        return
      }
      guard let destinationURL = savePanel.url else {
        self.isExportingLogs = false
        return
      }

      Task {
        do {
          try await createLogZipBundle(destinationURL: destinationURL)
          self.isExportingLogs = false
          await MainActor.run {
            window.contentViewController?.presentingViewController?.dismiss(self)
          }
        } catch {
          self.isExportingLogs = false
          await MainActor.run {
            // Show alert
          }
        }
      }
    }
  }
#elseif os(iOS)
  func exportLogsButtonTapped() {
    self.isExportingLogs = true
    Task {
      try await Task.sleep(nanoseconds: 2_000_000_000)
      self.isExportingLogs = false
    }
  }
#endif

  @discardableResult
  private func createLogZipBundle(destinationURL: URL?) async throws -> URL {
    let fileManager = FileManager.default
    guard let logFilesFolderURL = SharedAccess.logFolderURL else {
      throw SettingsViewError.logFolderIsUnavailable
    }
    let zipFileURL = destinationURL ?? fileManager.temporaryDirectory.appendingPathComponent("firezone_logs.zip")
    if fileManager.fileExists(atPath: zipFileURL.path) {
      try fileManager.removeItem(at: zipFileURL)
    }
    let task = Task.detached(priority: .userInitiated) { () -> URL in
      try FileManager.default.zipItem(at: logFilesFolderURL, to: zipFileURL)
      return zipFileURL
    }
    return try await task.value
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
