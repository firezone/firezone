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
  private let logger = Logger.make(for: SettingsViewModel.self)

  @Dependency(\.authStore) private var authStore

  var tunnelAuthStatus: TunnelAuthStatus {
    authStore.tunnelStore.tunnelAuthStatus
  }

  @Published var advancedSettings: AdvancedSettings

  public var onSettingsSaved: () -> Void = unimplemented()
  private var cancellables = Set<AnyCancellable>()

  public init() {
    advancedSettings = AdvancedSettings.defaultValue
    loadSettings()
  }

  func loadSettings() {
    Task {
      authStore.tunnelStore.$tunnelAuthStatus
        .first { $0.isInitialized }
        .receive(on: RunLoop.main)
        .sink { [weak self] tunnelAuthStatus in
          guard let self = self else { return }
          self.advancedSettings =
            authStore.tunnelStore.advancedSettings() ?? AdvancedSettings.defaultValue
        }
        .store(in: &cancellables)
    }
  }

  func saveAdvancedSettings() {
    let isChanged = (authStore.tunnelStore.advancedSettings() != advancedSettings)
    guard isChanged else {
      advancedSettings.isSavedToDisk = true
      return
    }
    Task {
      if case .signedIn = self.tunnelAuthStatus {
        await authStore.signOut()
      }
      let authBaseURLString = advancedSettings.authBaseURLString
      guard URL(string: authBaseURLString) != nil else {
        logger.error(
          "Not saving advanced settings because authBaseURL '\(authBaseURLString, privacy: .public)' is invalid"
        )
        return
      }
      do {
        try await authStore.tunnelStore.saveAdvancedSettings(advancedSettings)
      } catch {
        logger.error("Error saving advanced settings to tunnel store: \(error, privacy: .public)")
      }
      await MainActor.run {
        advancedSettings.isSavedToDisk = true
      }
    }
  }
}

public struct SettingsView: View {
  private let logger = Logger.make(for: SettingsView.self)

  @ObservedObject var model: SettingsViewModel
  @Environment(\.dismiss) var dismiss

  enum ConfirmationAlertContinueAction: Int {
    case none
    case saveAdvancedSettings
    case saveAllSettingsAndDismiss

    func performAction(on view: SettingsView) {
      switch self {
      case .none:
        break
      case .saveAdvancedSettings:
        view.saveAdvancedSettings()
      case .saveAllSettingsAndDismiss:
        view.saveAllSettingsAndDismiss()
      }
    }
  }

  @State private var isExportingLogs = false
  @State private var isShowingConfirmationAlert = false
  @State private var confirmationAlertContinueAction: ConfirmationAlertContinueAction = .none

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
    static let forAdvanced = try! AttributedString(
      markdown: """
        **WARNING:** These settings are intended for internal debug purposes **only**. \
        Changing these is not supported and will disrupt access to your Firezone resources.
        """)
  }

  public init(model: SettingsViewModel) {
    self.model = model
  }

  public var body: some View {
    #if os(iOS)
      NavigationView {
        TabView {
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
              let action = ConfirmationAlertContinueAction.saveAllSettingsAndDismiss
              if case .signedIn = model.tunnelAuthStatus {
                self.confirmationAlertContinueAction = action
                self.isShowingConfirmationAlert = true
              } else {
                action.performAction(on: self)
              }
            }
            .disabled(
              (model.advancedSettings.isSavedToDisk || !model.advancedSettings.isValid)
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
      .alert(
        "Saving settings will sign you out",
        isPresented: $isShowingConfirmationAlert,
        presenting: confirmationAlertContinueAction,
        actions: { confirmationAlertContinueAction in
          Button("Cancel", role: .cancel) {
            // Nothing to do
          }
          Button("Continue") {
            confirmationAlertContinueAction.performAction(on: self)
          }
        },
        message: { _ in
          Text("Changing settings will sign you out and disconnect you from resources")
        }
      )

    #elseif os(macOS)
      VStack {
        TabView {
          advancedTab
            .tabItem {
              Text("Advanced")
            }
        }
        .padding(20)
      }
      .alert(
        "Saving settings will sign you out",
        isPresented: $isShowingConfirmationAlert,
        presenting: confirmationAlertContinueAction,
        actions: { confirmationAlertContinueAction in
          Button("Cancel", role: .cancel) {
            // Nothing to do
          }
          Button("Continue", role: .destructive) {
            confirmationAlertContinueAction.performAction(on: self)
          }
        },
        message: { _ in
          Text("Changing settings will sign you out and disconnect you from resources")
        }
      )
      .onDisappear(perform: { self.loadSettings() })
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
                  let action = ConfirmationAlertContinueAction.saveAdvancedSettings
                  if case .signedIn = model.tunnelAuthStatus {
                    self.confirmationAlertContinueAction = action
                    self.isShowingConfirmationAlert = true
                  } else {
                    action.performAction(on: self)
                  }
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
                .submitLabel(.done)
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
                .submitLabel(.done)
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
                .submitLabel(.done)
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

  func saveAdvancedSettings() {
    model.saveAdvancedSettings()
  }

  func saveAllSettingsAndDismiss() {
    model.saveAdvancedSettings()
    dismiss()
  }

  func loadSettings() {
    model.loadSettings()
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
