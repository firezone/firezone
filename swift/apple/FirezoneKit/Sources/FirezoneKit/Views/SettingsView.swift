//
//  SettingsView.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Combine
import OSLog
import SwiftUI

enum SettingsViewError: Error {
  case logFolderIsUnavailable
}

@MainActor
public final class SettingsViewModel: ObservableObject {
  let store: Store

  @Published var settings: Settings

  private var cancellables = Set<AnyCancellable>()

  public init(store: Store) {
    self.store = store
    self.settings = store.settings

    setupObservers()
  }

  func setupObservers() {
    // Load settings from saved VPN Profile
    store.$settings
      .receive(on: DispatchQueue.main)
      .sink { [weak self] settings in
        guard let self = self else { return }

        self.settings = settings
      }
      .store(in: &cancellables)
  }

  func saveSettings() {
    Task {
      if [.connected, .connecting, .reasserting].contains(store.status) {
        _ = try await store.signOut()
      }
      do {
        try await store.save(settings)
      } catch {
        Log.app.error("Error saving settings to tunnel store: \(error)")
      }
    }
  }

  func calculateLogDirSize() -> String? {
    Log.app.log("\(#function)")

    guard let logFilesFolderURL = SharedAccess.logFolderURL else {
      Log.app.error("\(#function): Log folder is unavailable")
      return nil
    }

    let fileManager = FileManager.default

    var totalSize = 0
    fileManager.forEachFileUnder(
      logFilesFolderURL,
      including: [
        .totalFileAllocatedSizeKey,
        .totalFileSizeKey,
        .isRegularFileKey,
      ]
    ) { url, resourceValues in
      if resourceValues.isRegularFile ?? false {
        totalSize += (resourceValues.totalFileAllocatedSize ?? resourceValues.totalFileSize ?? 0)
      }
    }

    if Task.isCancelled {
      return nil
    }

    let byteCountFormatter = ByteCountFormatter()
    byteCountFormatter.countStyle = .file
    byteCountFormatter.allowsNonnumericFormatting = false
    byteCountFormatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB, .usePB]
    return byteCountFormatter.string(fromByteCount: Int64(totalSize))
  }

  func clearAllLogs() throws {
    Log.app.log("\(#function)")

    guard let logFilesFolderURL = SharedAccess.logFolderURL else {
      Log.app.error("\(#function): Log folder is unavailable")
      return
    }

    let fileManager = FileManager.default
    var unremovedFilesCount = 0
    fileManager.forEachFileUnder(
      logFilesFolderURL,
      including: [
        .isRegularFileKey
      ]
    ) { url, resourceValues in
      if resourceValues.isRegularFile ?? false {
        do {
          try fileManager.removeItem(at: url)
        } catch {
          unremovedFilesCount += 1
          Log.app.error("Unable to remove '\(url)': \(error)")
        }
      }
    }

    if unremovedFilesCount > 0 {
      Log.app.log("\(#function): Unable to remove \(unremovedFilesCount) files")
    }

  }
}

public struct SettingsView: View {
  @ObservedObject var favorites: Favorites
  @ObservedObject var model: SettingsViewModel
  @Environment(\.dismiss) var dismiss

  enum ConfirmationAlertContinueAction: Int {
    case none
    case saveSettings
    case saveAllSettingsAndDismiss

    func performAction(on view: SettingsView) {
      switch self {
      case .none:
        break
      case .saveSettings:
        view.saveSettings()
      case .saveAllSettingsAndDismiss:
        view.saveAllSettingsAndDismiss()
      }
    }
  }

  @State private var isCalculatingLogsSize = false
  @State private var calculatedLogsSize = "Unknown"
  @State private var isClearingLogs = false
  @State private var isExportingLogs = false
  @State private var isShowingConfirmationAlert = false
  @State private var confirmationAlertContinueAction: ConfirmationAlertContinueAction = .none

  @State private var calculateLogSizeTask: Task<(), Never>?

  #if os(iOS)
    @State private var logTempZipFileURL: URL?
    @State private var isPresentingExportLogShareSheet = false
  #endif

  struct PlaceholderText {
    static let authBaseURL = "Admin portal base URL"
    static let apiURL = "Control plane WebSocket URL"
    static let logFilter = "RUST_LOG-style filter string"
  }

  struct FootnoteText {
    static let forAdvanced = try! AttributedString(
      markdown: """
        **WARNING:** These settings are intended for internal debug purposes **only**. \
        Changing these will disrupt access to your Firezone resources.
        """)
  }

  public init(favorites: Favorites, model: SettingsViewModel) {
    self.favorites = favorites
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
            .badge(model.settings.isValid ? nil : "!")
          logsTab
            .tabItem {
              Image(systemName: "doc.text")
              Text("Diagnostic Logs")
            }
        }
        .toolbar {
          ToolbarItem(placement: .navigationBarTrailing) {
            Button("Save") {
              let action = ConfirmationAlertContinueAction.saveAllSettingsAndDismiss
              if case .connected = model.store.status {
                self.confirmationAlertContinueAction = action
                self.isShowingConfirmationAlert = true
              } else {
                action.performAction(on: self)
              }
            }
            .disabled(
              (model.settings == model.store.settings || !model.settings.isValid)
            )
          }
          ToolbarItem(placement: .navigationBarLeading) {
            Button("Cancel") {
              self.reloadSettings()
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
          logsTab
            .tabItem {
              Text("Diagnostic Logs")
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
      .onDisappear(perform: { self.reloadSettings() })
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
                get: { model.settings.authBaseURL },
                set: { model.settings.authBaseURL = $0 }
              ),
              prompt: Text(PlaceholderText.authBaseURL)
            )

            TextField(
              "API URL:",
              text: Binding(
                get: { model.settings.apiURL },
                set: { model.settings.apiURL = $0 }
              ),
              prompt: Text(PlaceholderText.apiURL)
            )

            TextField(
              "Log Filter:",
              text: Binding(
                get: { model.settings.logFilter },
                set: { model.settings.logFilter = $0 }
              ),
              prompt: Text(PlaceholderText.logFilter)
            )

            Text(FootnoteText.forAdvanced)
              .foregroundStyle(.secondary)

            HStack(spacing: 30) {
              Button(
                "Apply",
                action: {
                  let action = ConfirmationAlertContinueAction.saveSettings
                  if [.connected, .connecting, .reasserting].contains(model.store.status) {
                    self.confirmationAlertContinueAction = action
                    self.isShowingConfirmationAlert = true
                  } else {
                    action.performAction(on: self)
                  }
                }
              )
              .disabled(model.settings == model.store.settings || !model.settings.isValid)

              Button(
                "Reset to Defaults",
                action: {
                  model.settings = Settings.defaultValue
                  favorites.reset()
                }
              )
              .disabled(favorites.ids.isEmpty && model.settings == Settings.defaultValue)
            }
            .padding(.top, 5)
          }
          .padding(10)
          Spacer()
        }
        Spacer()
        HStack {
          Text("Build: \(AppInfoPlistConstants.gitSha)")
            .textSelection(.enabled)
            .foregroundColor(.gray)
          Spacer()
        }.padding([.leading, .bottom], 20)
      }
    #elseif os(iOS)
      VStack {
        Form {
          Section(
            content: {
              VStack(alignment: .leading, spacing: 2) {
                Text("Auth Base URL")
                  .foregroundStyle(.secondary)
                  .font(.caption)
                TextField(
                  PlaceholderText.authBaseURL,
                  text: Binding(
                    get: { model.settings.authBaseURL },
                    set: { model.settings.authBaseURL = $0 }
                  )
                )
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.done)
              }
              VStack(alignment: .leading, spacing: 2) {
                Text("API URL")
                  .foregroundStyle(.secondary)
                  .font(.caption)
                TextField(
                  PlaceholderText.apiURL,
                  text: Binding(
                    get: { model.settings.apiURL },
                    set: { model.settings.apiURL = $0 }
                  )
                )
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.done)
              }
              VStack(alignment: .leading, spacing: 2) {
                Text("Log Filter")
                  .foregroundStyle(.secondary)
                  .font(.caption)
                TextField(
                  PlaceholderText.logFilter,
                  text: Binding(
                    get: { model.settings.logFilter },
                    set: { model.settings.logFilter = $0 }
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
                    model.settings = Settings.defaultValue
                  }
                )
                .disabled(model.settings == Settings.defaultValue)
                Spacer()
              }
            },
            header: { Text("Advanced Settings") },
            footer: { Text(FootnoteText.forAdvanced) }
          )
        }
        Spacer()
        HStack {
          Text("Build: \(AppInfoPlistConstants.gitSha)")
            .textSelection(.enabled)
            .foregroundColor(.gray)
          Spacer()
        }.padding([.leading, .bottom], 20)
      }
    #endif
  }

  private var logsTab: some View {
    #if os(iOS)
      VStack {
        Form {
          Section(header: Text("Logs")) {
            LogDirectorySizeView(
              isProcessing: $isCalculatingLogsSize,
              sizeString: $calculatedLogsSize
            )
            .onAppear {
              self.refreshLogSize()
            }
            .onDisappear {
              self.cancelRefreshLogSize()
            }
            HStack {
              Spacer()
              ButtonWithProgress(
                systemImageName: "trash",
                title: "Clear Log Directory",
                isProcessing: $isClearingLogs,
                action: {
                  self.clearLogFiles()
                }
              )
              Spacer()
            }
          }
          Section {
            HStack {
              Spacer()
              ButtonWithProgress(
                systemImageName: "arrow.up.doc",
                title: "Export Logs",
                isProcessing: $isExportingLogs,
                action: {
                  self.isExportingLogs = true
                  Task {
                    let compressor = LogCompressor()
                    self.logTempZipFileURL = try await compressor.compressFolderReturningURL()
                    self.isPresentingExportLogShareSheet = true
                  }
                }
              )
              .sheet(isPresented: $isPresentingExportLogShareSheet) {
                if let logfileURL = self.logTempZipFileURL {
                  ShareSheetView(
                    localFileURL: logfileURL,
                    completionHandler: {
                      self.isPresentingExportLogShareSheet = false
                      self.isExportingLogs = false
                      self.logTempZipFileURL = nil
                    }
                  )
                  .onDisappear {
                    self.isPresentingExportLogShareSheet = false
                    self.isExportingLogs = false
                    self.logTempZipFileURL = nil
                  }
                }
              }
              Spacer()
            }
          }
        }
      }
    #elseif os(macOS)
      VStack {
        VStack(alignment: .leading, spacing: 10) {
          LogDirectorySizeView(
            isProcessing: $isCalculatingLogsSize,
            sizeString: $calculatedLogsSize
          )
          .onAppear {
            self.refreshLogSize()
          }
          .onDisappear {
            self.cancelRefreshLogSize()
          }
          HStack(spacing: 30) {
            ButtonWithProgress(
              systemImageName: "trash",
              title: "Clear Log Directory",
              isProcessing: $isClearingLogs,
              action: {
                self.clearLogFiles()
              }
            )
            ButtonWithProgress(
              systemImageName: "arrow.up.doc",
              title: "Export Logs",
              isProcessing: $isExportingLogs,
              action: {
                self.exportLogsWithSavePanelOnMac()
              }
            )
          }
        }
      }
    #else
      #error("Unsupported platform")
    #endif
  }

  func saveSettings() {
    model.saveSettings()
  }

  func saveAllSettingsAndDismiss() {
    model.saveSettings()
    dismiss()
  }

  func reloadSettings() {
    model.settings = model.store.settings
    dismiss()
  }

  #if os(macOS)
    func exportLogsWithSavePanelOnMac() {
      let compressor = LogCompressor()
      self.isExportingLogs = true

      let savePanel = NSSavePanel()
      savePanel.prompt = "Save"
      savePanel.nameFieldLabel = "Save log zip bundle to:"
      savePanel.nameFieldStringValue = compressor.fileName

      guard
        let window = NSApp.windows.first(where: {
          $0.identifier?.rawValue.hasPrefix("firezone-settings") ?? false
        })
      else {
        self.isExportingLogs = false
        Log.app.log("Settings window not found. Can't show save panel.")
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
            try await compressor.compressFolder(destinationURL: destinationURL)
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

  func refreshLogSize() {
    guard !self.isCalculatingLogsSize else {
      return
    }
    self.isCalculatingLogsSize = true
    self.calculateLogSizeTask = Task.detached(priority: .userInitiated) {
      let calculatedLogsSize = await model.calculateLogDirSize()
      await MainActor.run {
        self.calculatedLogsSize = calculatedLogsSize ?? "Unknown"
        self.isCalculatingLogsSize = false
        self.calculateLogSizeTask = nil
      }
    }
  }

  func cancelRefreshLogSize() {
    self.calculateLogSizeTask?.cancel()
  }

  func clearLogFiles() {
    self.isClearingLogs = true
    self.cancelRefreshLogSize()
    Task.detached(priority: .userInitiated) {
      try? await model.clearAllLogs()
      await MainActor.run {
        self.isClearingLogs = false
        if !self.isCalculatingLogsSize {
          self.refreshLogSize()
        }
      }
    }
  }
}

struct ButtonWithProgress: View {
  let systemImageName: String
  let title: String
  @Binding var isProcessing: Bool
  let action: () -> Void

  var body: some View {

    VStack {
      Button(action: action) {
        Label(
          title: { Text(title) },
          icon: {
            if isProcessing {
              ProgressView().controlSize(.small)
                .frame(maxWidth: 12, maxHeight: 12)
            } else {
              Image(systemName: systemImageName)
                .frame(maxWidth: 12, maxHeight: 12)
            }
          }
        )
        .labelStyle(.titleAndIcon)
      }
      .disabled(isProcessing)
    }
    .frame(minHeight: 30)
  }
}

struct LogDirectorySizeView: View {
  @Binding var isProcessing: Bool
  @Binding var sizeString: String

  var body: some View {
    HStack(spacing: 10) {
      #if os(macOS)
        Label(
          title: { Text("Log directory size:") },
          icon: {}
        )
      #elseif os(iOS)
        Label(
          title: { Text("Log directory size:") },
          icon: {}
        )
        .foregroundColor(.secondary)
        Spacer()
      #endif
      Label(
        title: {
          if isProcessing {
            Text("")
          } else {
            Text(sizeString)
          }
        },
        icon: {
          if isProcessing {
            ProgressView().controlSize(.small)
              .frame(maxWidth: 12, maxHeight: 12)
          }
        }
      )
    }
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
