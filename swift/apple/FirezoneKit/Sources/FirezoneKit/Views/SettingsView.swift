//
//  SettingsView.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

// TODO: Refactor to fix file length
// swiftlint:disable file_length

import Combine
import OSLog
import SwiftUI

enum SettingsViewError: Error {
  case logFolderIsUnavailable

  var localizedDescription: String {
    switch self {
    case .logFolderIsUnavailable:
      return "Log folder is unavailable."
    }
  }
}

extension FileManager {
  enum FileManagerError: Error {
    case invalidURL(URL, Error)

    var localizedDescription: String {
      switch self {
      case .invalidURL(let url, let error):
        return "Unable to get resource value for '\(url)': \(error)"
      }
    }
  }

  func forEachFileUnder(
    _ dirURL: URL,
    including resourceKeys: Set<URLResourceKey>,
    handler: (URL, URLResourceValues) -> Void
  ) {
    // Deep-traverses the directory at dirURL
    guard
      let enumerator = self.enumerator(
        at: dirURL,
        includingPropertiesForKeys: [URLResourceKey](resourceKeys),
        options: [],
        errorHandler: nil
      )
    else {
      return
    }

    for item in enumerator.enumerated() {
      if Task.isCancelled { break }
      guard let url = item.element as? URL else { continue }
      do {
        let resourceValues = try url.resourceValues(forKeys: resourceKeys)
        handler(url, resourceValues)
      } catch {
        Log.error(FileManagerError.invalidURL(url, error))
      }
    }
  }
}

// TODO: Refactor body length
// swiftlint:disable:next type_body_length
public struct SettingsView: View {
  @EnvironmentObject var store: Store
  @Environment(\.dismiss) var dismiss
  @State var settings = Settings.defaultValue

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
    static let forAdvanced = try? AttributedString(
      markdown: """
        **WARNING:** These settings are intended for internal debug purposes **only**. \
        Changing these will disrupt access to your Firezone resources.
        """
    )
  }

  public init() {}

  public var body: some View {
    #if os(iOS)
      NavigationView {
        TabView {
          advancedTab
            .tabItem {
              Image(systemName: "slider.horizontal.3")
              Text("Advanced")
            }
            .badge(settings.isValid ? nil : "!")
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
              if case .connected = store.status {
                self.confirmationAlertContinueAction = action
                self.isShowingConfirmationAlert = true
              } else {
                action.performAction(on: self)
              }
            }
            .disabled(
              (settings == store.settings || !settings.isValid)
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
      .onAppear {
        settings = store.settings
      }

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
      .onAppear {
        settings = store.settings
      }
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
                get: { settings.authBaseURL },
                set: { settings.authBaseURL = $0 }
              ),
              prompt: Text(PlaceholderText.authBaseURL)
            )

            TextField(
              "API URL:",
              text: Binding(
                get: { settings.apiURL },
                set: { settings.apiURL = $0 }
              ),
              prompt: Text(PlaceholderText.apiURL)
            )

            TextField(
              "Log Filter:",
              text: Binding(
                get: { settings.logFilter },
                set: { settings.logFilter = $0 }
              ),
              prompt: Text(PlaceholderText.logFilter)
            )

            Text(FootnoteText.forAdvanced ?? "")
              .foregroundStyle(.secondary)

            HStack(spacing: 30) {
              Button(
                "Apply",
                action: {
                  let action = ConfirmationAlertContinueAction.saveSettings
                  if [.connected, .connecting, .reasserting].contains(store.status) {
                    self.confirmationAlertContinueAction = action
                    self.isShowingConfirmationAlert = true
                  } else {
                    action.performAction(on: self)
                  }
                }
              )
              .disabled(settings == store.settings || !store.settings.isValid)

              Button(
                "Reset to Defaults",
                action: {
                  settings = Settings.defaultValue
                  store.favorites.reset()
                }
              )
              .disabled(store.favorites.isEmpty() && settings == Settings.defaultValue)
            }
            .padding(.top, 5)
          }
          .padding(10)
          Spacer()
        }
        Spacer()
        HStack {
          Text("Build: \(BundleHelper.gitSha)")
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
                    get: { settings.authBaseURL },
                    set: { settings.authBaseURL = $0 }
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
                    get: { settings.apiURL },
                    set: { settings.apiURL = $0 }
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
                    get: { settings.logFilter },
                    set: { settings.logFilter = $0 }
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
                    settings = Settings.defaultValue
                    store.favorites.reset()
                  }
                )
                .disabled(store.favorites.isEmpty() && settings == Settings.defaultValue)
                Spacer()
              }
            },
            header: { Text("Advanced Settings") },
            footer: { Text(FootnoteText.forAdvanced ?? "") }
          )
        }
        Spacer()
        HStack {
          Text("Build: \(BundleHelper.gitSha)")
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
                  Task.detached(priority: .background) {
                    let archiveURL = LogExporter.tempFile()
                    try await LogExporter.export(to: archiveURL)
                    await MainActor.run {
                      self.logTempZipFileURL = archiveURL
                      self.isPresentingExportLogShareSheet = true
                    }
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

  func saveAllSettingsAndDismiss() {
    saveSettings()
    dismiss()
  }

  func reloadSettings() {
    settings = store.settings
    dismiss()
  }

  #if os(macOS)
    func exportLogsWithSavePanelOnMac() {
      self.isExportingLogs = true

      let savePanel = NSSavePanel()
      savePanel.prompt = "Save"
      savePanel.nameFieldLabel = "Save log archive to:"
      let fileName = "firezone_logs_\(LogExporter.now()).aar"

      savePanel.nameFieldStringValue = fileName

      guard
        let window = NSApp.windows.first(where: {
          $0.identifier?.rawValue.hasPrefix("firezone-settings") ?? false
        })
      else {
        self.isExportingLogs = false
        Log.log("Settings window not found. Can't show save panel.")
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
            try await LogExporter.export(
              to: destinationURL,
              with: store.ipcClient()
            )

            window.contentViewController?.presentingViewController?.dismiss(self)
          } catch {
            if let error = error as? IPCClient.Error,
               case IPCClient.Error.noIPCData = error {
              Log.warning("\(#function): Error exporting logs: \(error). Is the XPC service running?")
            } else {
              Log.error(error)
            }

            await macOSAlert.show(for: error)
          }

          self.isExportingLogs = false
        }
      }
    }
  #endif

  func refreshLogSize() {
    guard !self.isCalculatingLogsSize else {
      return
    }
    self.isCalculatingLogsSize = true
    self.calculateLogSizeTask =
    Task.detached(priority: .background) {
      let calculatedLogsSize = await calculateLogDirSize()
      await MainActor.run {
        self.calculatedLogsSize = calculatedLogsSize
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
    Task.detached(priority: .background) {
      do { try await clearAllLogs() } catch { Log.error(error) }
      await MainActor.run {
        self.isClearingLogs = false
        if !self.isCalculatingLogsSize {
          self.refreshLogSize()
        }
      }
    }
  }

  func saveSettings() {
    Task {
      do {
        if [.connected, .connecting, .reasserting].contains(store.status) {
          try self.store.signOut()
        }

        try await store.saveSettings(settings)
      } catch {
        Log.error(error)
      }
    }
  }

  // Calculates the total size of our logs by summing the size of the
  // app, tunnel, and connlib log directories.
  //
  // On iOS, SharedAccess.logFolderURL is a single folder that contains all
  // three directories, but on macOS, the app log directory lives in a different
  // Group Container than tunnel and connlib directories, so we use IPC to make
  // a call to sum both the tunnel and connlib directories.
  //
  // Unfortunately the IPC method doesn't work on iOS because the tunnel process
  // is not started on demand, so the IPC calls hang. Thus, we use separate code
  // paths for iOS and macOS.
  func calculateLogDirSize() async -> String {
    Log.log("\(#function)")

    guard let logFilesFolderURL = SharedAccess.logFolderURL else {
      return "Unknown"
    }

    let logFolderSize = await Log.size(of: logFilesFolderURL)

    do {
#if os(macOS)
      let providerLogFolderSize = try await store.ipcClient().getLogFolderSize()
      let totalSize = logFolderSize + providerLogFolderSize
#else
      let totalSize = logFolderSize
#endif

      let byteCountFormatter = ByteCountFormatter()
      byteCountFormatter.countStyle = .file
      byteCountFormatter.allowsNonnumericFormatting = false
      byteCountFormatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB, .usePB]

      return byteCountFormatter.string(fromByteCount: Int64(totalSize))

    } catch {
      if let error = error as? IPCClient.Error,
         case IPCClient.Error.noIPCData = error {
        // Will happen if the extension is not enabled
        Log.warning("\(#function): Unable to count logs: \(error). Is the XPC service running?")
      } else {
        Log.error(error)
      }

      return "Unknown"
    }
  }

  // On iOS, all the logs are stored in one directory.
  // On macOS, we need to clear logs from the app process, then call over IPC
  // to clear the provider's log directory.
  func clearAllLogs() async throws {
    Log.log("\(#function)")

    try Log.clear(in: SharedAccess.logFolderURL)

#if os(macOS)
    try await store.clearLogs()
#endif
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
