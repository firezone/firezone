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

  let authStore: AuthStore

  var tunnelAuthStatus: TunnelAuthStatus {
    authStore.tunnelStore.tunnelAuthStatus
  }

  @Published var advancedSettings: AdvancedSettings

  public var onSettingsSaved: () -> Void = unimplemented()
  private var cancellables = Set<AnyCancellable>()

  public init(authStore: AuthStore) {
    self.authStore = authStore
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
          "Not saving advanced settings because authBaseURL '\(authBaseURLString)' is invalid"
        )
        return
      }
      do {
        try await authStore.tunnelStore.saveAdvancedSettings(advancedSettings)
      } catch {
        logger.error("Error saving advanced settings to tunnel store: \(error)")
      }
      await MainActor.run {
        advancedSettings.isSavedToDisk = true
      }
    }
  }

  func calculateLogDirSize(logger: Logger) -> String? {
    logger.log("\(#function)")

    let startTime = DispatchTime.now()
    guard let logFilesFolderURL = SharedAccess.logFolderURL else {
      logger.error("\(#function): Log folder is unavailable")
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
      ],
      logger: logger
    ) { url, resourceValues in
      if resourceValues.isRegularFile ?? false {
        totalSize += (resourceValues.totalFileAllocatedSize ?? resourceValues.totalFileSize ?? 0)
      }
    }

    if Task.isCancelled {
      return nil
    }

    let elapsedTime =
      (DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000
    logger.log("\(#function): Finished calculating (\(totalSize) bytes) in \(elapsedTime) ms")

    let byteCountFormatter = ByteCountFormatter()
    byteCountFormatter.countStyle = .file
    byteCountFormatter.allowsNonnumericFormatting = false
    byteCountFormatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB, .usePB]
    return byteCountFormatter.string(fromByteCount: Int64(totalSize))
  }

  func clearAllLogs(logger: Logger) throws {
    logger.log("\(#function)")

    let startTime = DispatchTime.now()
    guard let logFilesFolderURL = SharedAccess.logFolderURL else {
      logger.error("\(#function): Log folder is unavailable")
      return
    }

    let fileManager = FileManager.default
    var unremovedFilesCount = 0
    fileManager.forEachFileUnder(
      logFilesFolderURL,
      including: [
        .isRegularFileKey
      ],
      logger: logger
    ) { url, resourceValues in
      if resourceValues.isRegularFile ?? false {
        do {
          try fileManager.removeItem(at: url)
        } catch {
          unremovedFilesCount += 1
          logger.error("Unable to remove '\(url)': \(error)")
        }
      }
    }

    let elapsedTime =
      (DispatchTime.now().uptimeNanoseconds - startTime.uptimeNanoseconds) / 1_000_000
    logger.log("\(#function): Finished removing log files in \(elapsedTime) ms")

    if unremovedFilesCount > 0 {
      logger.log("\(#function): Unable to remove \(unremovedFilesCount) files")
    }
  }
}

extension FileManager {
  func forEachFileUnder(
    _ dirURL: URL,
    including resourceKeys: Set<URLResourceKey>,
    logger: Logger,
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
        logger.error("Unable to get resource value for '\(url)': \(error)")
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
        }
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
                    self.logTempZipFileURL = try await createLogZipBundle()
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

  func refreshLogSize() {
    guard !self.isCalculatingLogsSize else {
      return
    }
    self.isCalculatingLogsSize = true
    self.calculateLogSizeTask = Task.detached(priority: .userInitiated) {
      let calculatedLogsSize = await model.calculateLogDirSize(logger: self.logger)
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
      try? await model.clearAllLogs(logger: self.logger)
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
