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

  #if os(iOS)
    @State private var logTempZipFileURL: URL?
    @State private var isPresentingExportLogShareSheet = false
  #endif

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
      NavigationView {
        tabView
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
          .navigationTitle("Settings")
          .navigationBarTitleDisplayMode(.inline)
      }
    #elseif os(macOS)
      VStack {
        tabView
          .padding(20)
      }
    #else
      #error("Unsupported platform")
    #endif
  }

  private var tabView: some View {
    TabView {
      accountTab
        .tabItem {
          Image(systemName: "person.crop.circle.fill")
          Text("Account")
        }
        .badge(isTeamIdValid(model.settings.accountId) ? nil : "!")

      exportLogsTab
        .tabItem {
          Image(systemName: "doc.text")
          Text("Logs")
        }
    }
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
                    get: { model.settings.accountId },
                    set: { model.settings.accountId = $0 }
                  ),
                  prompt: Text("account-id")
                )
                .frame(maxWidth: 240)
                .padding(10)
                Spacer()
              }
            },
            footer: {
              Text("Your account ID is provided by your admin")
                .foregroundStyle(.secondary)
            }
          )
        }
        Spacer()
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
        .padding(10)
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
                  "account-id",
                  text: Binding(
                    get: { model.settings.accountId },
                    set: { model.settings.accountId = $0 }
                  )
                )
              }
            },
            header: { Text("Account") },
            footer: { Text("Your account ID is provided by your admin") }
          )
        }
      }
    #else
      #error("Unsupported platform")
    #endif
  }

  private var exportLogsTab: some View {
    #if os(iOS)
      VStack {
        Form {
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
    #elseif os(macOS)
      VStack {
        ExportLogsButton(isProcessing: $isExportingLogs) {
          self.exportLogsWithSavePanelOnMac()
        }
      }
    #else
      #error("Unsupported platform")
    #endif
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
            .multilineTextAlignment(.leading)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity)
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
