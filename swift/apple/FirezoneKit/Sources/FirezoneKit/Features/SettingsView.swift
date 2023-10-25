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

  @Published var settings: Settings
  @Published var apiURLString: String
  @Published var authBaseURLString: String

  public var onSettingsSaved: () -> Void = unimplemented()
  private var cancellables = Set<AnyCancellable>()

  public init() {
    settings = Settings()
    apiURLString = Settings().apiURL.absoluteString
    authBaseURLString = Settings().authBaseURL.absoluteString
    load()
  }

  func load() {
    Task {
      authStore.tunnelStore.$tunnelState
        .filter { $0.isInitialized }
        .receive(on: RunLoop.main)
        .sink { [weak self] tunnelState in
          guard let self = self else { return }
          self.settings = Settings(
            authBaseURL: tunnelState.authBaseURL(),
            apiURL: tunnelState.apiURL(),
            logFilter: tunnelState.logFilter(),
            accountId: tunnelState.accountId()
          )
        }
        .store(in: &cancellables)
    }
  }

  func save() {
    Task {
      let tunnelState: TunnelState = await {
        return await authStore.tunnelStateForAccount(
          authBaseURL: URL(string: authBaseURLString)!,
          accountId: settings.accountId,
          apiURL: URL(string: apiURLString)!,
          logFilter: settings.logFilter
        )
      }()
      // TODO: If fields have changed, warn user they'll be signed out.
      try await authStore.tunnelStore.setState(tunnelState)
      onSettingsSaved()
    }
  }
}

public struct SettingsView: View {
  private let logger = Logger.make(for: SettingsView.self)

  @ObservedObject var model: SettingsViewModel
  @Environment(\.dismiss) var dismiss

  // TODO: Set allowed charactersets for logFilter, authBaseURL, and apiURL
  let accountIdAllowedCharacterSet: CharacterSet
  @State private var isExportingLogs = false

  #if os(iOS)
    @State private var logTempZipFileURL: URL?
    @State private var isPresentingExportLogShareSheet = false
  #endif

  public init(model: SettingsViewModel) {
    self.model = model
    self.accountIdAllowedCharacterSet = {
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
        VStack(spacing: 10) {
          form
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
        .toolbar {
          ToolbarItem(placement: .navigationBarTrailing) {
            Button("Save") {
              self.saveButtonTapped()
            }
            .disabled(areFieldsInvalid())
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
      VStack(spacing: 15) {
        form
        HStack(spacing: 15) {
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
          .disabled(areFieldsInvalid())
        }
        ExportLogsButton(isProcessing: $isExportingLogs) {
          self.exportLogsWithSavePanelOnMac()
        }
      }
    }
  #endif

  private func areFieldsInvalid() -> Bool {
    // Check if any field is empty
    if model.settings.accountId.isEmpty
      || model.authBaseURLString.isEmpty
      || model.apiURLString.isEmpty
      || model.settings.logFilter.isEmpty
    {
      return true
    }

    // Check if accountId contains only valid characters
    if !model.settings.accountId.unicodeScalars.allSatisfy({
      accountIdAllowedCharacterSet.contains($0)
    }) {
      return true
    }

    // Check if authBaseURLString is a valid URL
    if URL(string: model.authBaseURLString) == nil {
      return true
    }

    // Check if apiURLString is a valid URL
    if URL(string: model.apiURLString) == nil {
      return true
    }

    // If none of the above conditions are met, return false
    return false
  }

  private var form: some View {
    Form {
      Section(header: Text("Required")) {
        FormTextField(
          title: "Account ID",
          placeholder: "Provided by your admin",
          text: Binding(
            get: { model.settings.accountId },
            set: { model.settings.accountId = $0 }
          )
        )
      }
      // TODO: Add a button to hide/show advanced settings and make hidden by default
      Section(header: Text("Advanced")) {
        FormTextField(
          title: "Auth Base URL",
          placeholder: "Admin portal base URL",
          text: Binding(
            get: { model.authBaseURLString },
            set: { model.authBaseURLString = $0 }
          )
        )
        FormTextField(
          title: "API URL",
          placeholder: "Control plane WebSocket URL",
          text: Binding(
            get: { model.apiURLString },
            set: { model.apiURLString = $0 }
          )
        )
        FormTextField(
          title: "Log Filter",
          placeholder: "RUST_LOG-style log filter string",
          text: Binding(
            get: { model.settings.logFilter },
            set: { model.settings.logFilter = $0 }
          )
        )
      }
    }.toolbar {
      ToolbarItem(placement: .primaryAction) {
      }
    }
    .navigationTitle("Settings")
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
  let placeholder: String
  let text: Binding<String>

  var body: some View {
    #if os(iOS)
      HStack {
        Text(title)
        TextField(title, text: text, prompt: Text(placeholder))
          .autocorrectionDisabled()
          .multilineTextAlignment(.leading)
          .foregroundColor(.secondary)
          .frame(maxWidth: .infinity)
          .textInputAutocapitalization(.never)
      }
    #elseif os(macOS)
      HStack(spacing: 30) {
        Spacer()
        VStack(alignment: .leading) {
          TextField(title, text: text, prompt: Text(placeholder))
            .autocorrectionDisabled()
            .multilineTextAlignment(.leading)
            .foregroundColor(.secondary)
            .frame(minWidth: 360, maxWidth: 360)
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
