//
//  SettingsView.swift
//  (c) 2023 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Combine
import Dependencies
import OSLog
import SwiftUI
import XCTestDynamicOverlay
import ZIPFoundation

enum SettingsViewError: Error {
  case logFolderIsUnavailable
}

public final class SettingsViewModel: ObservableObject {
  @Dependency(\.authStore) private var authStore

  @Published var accountSettings: AccountSettings
  @Published var advancedSettings: AdvancedSettings

  public var onSettingsSaved: () -> Void = unimplemented()
  private var cancellables = Set<AnyCancellable>()

  public init() {
    accountSettings = AccountSettings()
    advancedSettings = AdvancedSettings.defaultValue
    loadAccountSettings()
    loadAdvancedSettings()
  }

  func loadAccountSettings() {
    Task {
      authStore.tunnelStore.$tunnelAuthStatus
        .filter { $0.isInitialized }
        .receive(on: RunLoop.main)
        .sink { [weak self] tunnelAuthStatus in
          guard let self = self else { return }
          self.accountSettings = AccountSettings(accountId: tunnelAuthStatus.accountId() ?? "")
        }
        .store(in: &cancellables)
    }
  }

  func saveAccountSettings() {
    Task {
      let accountId = await authStore.loginStatus.accountId
      if accountId == accountSettings.accountId {
        // Not changed
        await MainActor.run {
          accountSettings.isSavedToDisk = true
        }
        return
      }
      let tunnelAuthStatus: TunnelAuthStatus = await {
        if accountSettings.accountId.isEmpty {
          return .accountNotSetup
        } else {
          return await authStore.tunnelAuthStatusForAccount(accountId: accountSettings.accountId)
        }
      }()
      try await authStore.tunnelStore.saveAuthStatus(tunnelAuthStatus)
      onSettingsSaved()
      await MainActor.run {
        accountSettings.isSavedToDisk = true
      }
    }
  }

  func loadAdvancedSettings() {
    advancedSettings = authStore.tunnelStore.advancedSettings() ?? AdvancedSettings.defaultValue
  }

  func saveAdvancedSettings() {
    Task {
      guard let authBaseURL = URL(string: advancedSettings.authBaseURLString) else {
        fatalError("Saved authBaseURL is invalid")
      }
      try await authStore.tunnelStore.saveAdvancedSettings(advancedSettings)
      await MainActor.run {
        advancedSettings.isSavedToDisk = true
      }
      var isChanged = false
      await authStore.setAuthBaseURL(authBaseURL, isChanged: &isChanged)
      if isChanged {
        // Update tunnelAuthStatus looking for the new authBaseURL in the keychain
        saveAccountSettings()
      }
    }
  }
}

public struct SettingsView: View {
  private let logger = Logger.make(for: SettingsView.self)

  @ObservedObject var model: SettingsViewModel
  @Environment(\.dismiss) var dismiss

  @State private var isExportingLogs = false

  #if os(iOS)
    @State private var logTempZipFileURL: URL?
    @State private var isPresentingExportLogShareSheet = false
  #endif

  struct PlaceholderText {
    static let accountId = "account-id"
    static let authBaseURL = "Admin portal base URL"
    static let apiURL = "Control plane WebSocket URL"
    static let logFilter = "RUST_LOG-style filter string"
  }

  struct FootnoteText {
    static let forAccount = "Your account ID is provided by your admin"
    static let forAdvanced = """
      Use the default values unless you know what you're doing. \
      Changing them might disrupt access to your Firezone resources.
      """
  }

  public init(model: SettingsViewModel) {
    self.model = model
  }

  public var body: some View {
    #if os(iOS)
      NavigationView {
        TabView {
          accountTab
            .tabItem {
              Image(systemName: "person.3.fill")
              Text("Account")
            }
            .badge(model.accountSettings.isValid ? nil : "!")

          advancedTab
            .tabItem {
              Image(systemName: "slider.horizontal.3")
              Text("Advanced")
            }
            .badge(model.advancedSettings.isValid ? nil : "!")
        }
        .toolbar {
          ToolbarItem(placement: .navigationBarTrailing) {
            Button("Save") {
              self.saveSettings()
            }
            .disabled(
              (model.accountSettings.isSavedToDisk && model.advancedSettings.isSavedToDisk)
                || !model.accountSettings.isValid
            )
          }
          ToolbarItem(placement: .navigationBarLeading) {
            Button("Cancel") {
              self.loadSettings()
            }
          }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
      }
    #elseif os(macOS)
      VStack {
        TabView {
          accountTab
            .tabItem {
              Text("Account")
            }
          advancedTab
            .tabItem {
              Text("Advanced")
            }
        }
        .padding(20)
      }
      .onDisappear(perform: { self.loadSettings() })
    #else
      #error("Unsupported platform")
    #endif
  }

  private var accountTab: some View {
    #if os(macOS)
      VStack {
        Spacer()
        Form {
          Section(
            content: {
              HStack(spacing: 15) {
                Spacer()
                Text("Account ID:")
                TextField(
                  "",
                  text: Binding(
                    get: { model.accountSettings.accountId },
                    set: { model.accountSettings.accountId = $0 }
                  ),
                  prompt: Text(PlaceholderText.accountId)
                )
                .frame(maxWidth: 240)
                .onSubmit {
                  self.model.saveAccountSettings()
                }
                Spacer()
              }
            },
            footer: {
              Text(FootnoteText.forAccount)
                .foregroundStyle(.secondary)
            }
          )
          Button(
            "Apply",
            action: {
              self.model.saveAccountSettings()
            }
          )
          .disabled(
            model.accountSettings.isSavedToDisk
              || !model.accountSettings.isValid
          )
          .padding(.top, 5)
        }
        Spacer()
      }
    #elseif os(iOS)
      VStack {
        Form {
          Section(
            content: {
              HStack(spacing: 15) {
                Text("Account ID")
                  .foregroundStyle(.secondary)
                TextField(
                  PlaceholderText.accountId,
                  text: Binding(
                    get: { model.accountSettings.accountId },
                    set: { model.accountSettings.accountId = $0 }
                  )
                )
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
              }
            },
            header: { Text("Account") },
            footer: { Text(FootnoteText.forAccount) }
          )
        }
      }
    #else
      #error("Unsupported platform")
    #endif
  }

  private var advancedTab: some View {
    #if os(macOS)
      VStack {
        Spacer()
        HStack {
          Spacer()
          Form {
            TextField(
              "Auth Base URL:",
              text: Binding(
                get: { model.advancedSettings.authBaseURLString },
                set: { model.advancedSettings.authBaseURLString = $0 }
              ),
              prompt: Text(PlaceholderText.authBaseURL)
            )

            TextField(
              "API URL:",
              text: Binding(
                get: { model.advancedSettings.apiURLString },
                set: { model.advancedSettings.apiURLString = $0 }
              ),
              prompt: Text(PlaceholderText.apiURL)
            )

            TextField(
              "Log Filter:",
              text: Binding(
                get: { model.advancedSettings.connlibLogFilterString },
                set: { model.advancedSettings.connlibLogFilterString = $0 }
              ),
              prompt: Text(PlaceholderText.logFilter)
            )

            Text(FootnoteText.forAdvanced)
              .foregroundStyle(.secondary)

            HStack(spacing: 30) {
              Button(
                "Apply",
                action: {
                  self.model.saveAdvancedSettings()
                }
              )
              .disabled(model.advancedSettings.isSavedToDisk || !model.advancedSettings.isValid)

              Button(
                "Reset to Defaults",
                action: {
                  self.restoreAdvancedSettingsToDefaults()
                }
              )
              .disabled(model.advancedSettings == AdvancedSettings.defaultValue)
            }
            .padding(.top, 5)
          }
          .padding(10)
          Spacer()
        }
        Spacer()
        HStack {
          Spacer()
          ExportLogsButton(isProcessing: $isExportingLogs) {
            self.exportLogsWithSavePanelOnMac()
          }
          Spacer()
        }
        Spacer()
      }
    #elseif os(iOS)
      VStack {
        Form {
          Section(
            content: {
              HStack(spacing: 15) {
                Text("Auth Base URL")
                  .foregroundStyle(.secondary)
                TextField(
                  PlaceholderText.authBaseURL,
                  text: Binding(
                    get: { model.advancedSettings.authBaseURLString },
                    set: { model.advancedSettings.authBaseURLString = $0 }
                  )
                )
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
              }
              HStack(spacing: 15) {
                Text("API URL")
                  .foregroundStyle(.secondary)
                TextField(
                  PlaceholderText.apiURL,
                  text: Binding(
                    get: { model.advancedSettings.apiURLString },
                    set: { model.advancedSettings.apiURLString = $0 }
                  )
                )
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
              }
              HStack(spacing: 15) {
                Text("Log Filter")
                  .foregroundStyle(.secondary)
                TextField(
                  PlaceholderText.logFilter,
                  text: Binding(
                    get: { model.advancedSettings.connlibLogFilterString },
                    set: { model.advancedSettings.connlibLogFilterString = $0 }
                  )
                )
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
              }
              HStack {
                Spacer()
                Button(
                  "Reset to Defaults",
                  action: {
                    self.restoreAdvancedSettingsToDefaults()
                  }
                )
                .disabled(model.advancedSettings == AdvancedSettings.defaultValue)
                Spacer()
              }
            },
            header: { Text("Advanced Settings") },
            footer: { Text(FootnoteText.forAdvanced) }
          )
          Section(header: Text("Logs")) {
            HStack {
              Spacer()
              ExportLogsButton(isProcessing: $isExportingLogs) {
                self.isExportingLogs = true
                Task {
                  self.logTempZipFileURL = try await createLogZipBundle()
                  self.isPresentingExportLogShareSheet = true
                }
              }.sheet(isPresented: $isPresentingExportLogShareSheet) {
                if let logfileURL = self.logTempZipFileURL {
                  ShareSheetView(
                    localFileURL: logfileURL,
                    completionHandler: {
                      self.isPresentingExportLogShareSheet = false
                      self.isExportingLogs = false
                      self.logTempZipFileURL = nil
                    })
                }
              }
              Spacer()
            }
          }
        }
      }
    #endif
  }

  func saveSettings() {
    model.saveAccountSettings()
    model.saveAdvancedSettings()
    dismiss()
  }

  func loadSettings() {
    model.loadAccountSettings()
    model.loadAdvancedSettings()
    dismiss()
  }

  func restoreAdvancedSettingsToDefaults() {
    let defaultValue = AdvancedSettings.defaultValue
    model.advancedSettings.authBaseURLString = defaultValue.authBaseURLString
    model.advancedSettings.apiURLString = defaultValue.apiURLString
    model.advancedSettings.connlibLogFilterString = defaultValue.connlibLogFilterString
    model.saveAdvancedSettings()
  }

  #if os(macOS)
    func exportLogsWithSavePanelOnMac() {
      self.isExportingLogs = true

      let savePanel = NSSavePanel()
      savePanel.prompt = "Save"
      savePanel.nameFieldLabel = "Save log zip bundle to:"
      savePanel.nameFieldStringValue = logZipBundleFilename()

      guard
        let window = NSApp.windows.first(where: {
          $0.identifier?.rawValue.hasPrefix("firezone-settings") ?? false
        })
      else {
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
  #endif

  private func logZipBundleFilename() -> String {
    let dateFormatter = ISO8601DateFormatter()
    dateFormatter.formatOptions = [.withFullDate, .withTime, .withTimeZone]
    let timeStampString = dateFormatter.string(from: Date())
    return "firezone_logs_\(timeStampString).zip"
  }

  @discardableResult
  private func createLogZipBundle(destinationURL: URL? = nil) async throws -> URL {
    let fileManager = FileManager.default
    guard let logFilesFolderURL = SharedAccess.logFolderURL else {
      throw SettingsViewError.logFolderIsUnavailable
    }
    let zipFileURL =
      destinationURL
      ?? fileManager.temporaryDirectory.appendingPathComponent(logZipBundleFilename())
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
        }
      )
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
      VStack(spacing: 10) {
        Spacer()
        HStack(spacing: 5) {
          Text(title)
          Spacer()
          TextField(baseURLString, text: text, prompt: Text(placeholder))
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
        }
        Spacer()
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

#if os(iOS)
  struct ShareSheetView: UIViewControllerRepresentable {
    let localFileURL: URL
    let completionHandler: () -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
      let controller = UIActivityViewController(
        activityItems: [self.localFileURL],
        applicationActivities: [])
      controller.completionWithItemsHandler = { _, _, _, _ in
        self.completionHandler()
      }
      return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
      // Nothing to do
    }
  }
#endif

struct SettingsView_Previews: PreviewProvider {
  static var previews: some View {
    SettingsView(model: SettingsViewModel())
  }
}
