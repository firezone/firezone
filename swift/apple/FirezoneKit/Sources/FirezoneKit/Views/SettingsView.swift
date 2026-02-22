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
  case configurationNotInitialized

  var localizedDescription: String {
    switch self {
    case .logFolderIsUnavailable:
      return """
          Log folder is unavailable.
          Try restarting your device or reinstalling Firezone if this issue persists.
        """
    case .configurationNotInitialized:
      return """
          Configuration is not initialized.
          Try restarting your device or reinstalling Firezone if this issue persists.
        """
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

// TODO: Move business logic to ViewModel to remove dependency on Store and fix body length
public struct SettingsView: View {
  @StateObject private var viewModel: SettingsViewModel
  @Environment(\.dismiss) var dismiss
  @EnvironmentObject var errorHandler: GlobalErrorHandler

  private let store: Store
  private let configuration: Configuration

  @State private var isCalculatingLogsSize = false
  @State private var calculatedLogsSize = "Unknown"
  @State private var isClearingLogs = false
  @State private var isExportingLogs = false
  #if os(iOS)
    @State private var localSelectedSection: SettingsSection?
  #else
    @State private var localSelectedSection: SettingsSection? = .general
  #endif
  @FocusState private var focusedField: SettingsField?

  @State private var calculateLogSizeTask: Task<(), Never>?

  #if os(iOS)
    @State private var logTempZipFileURL: URL?
    @State private var isPresentingExportLogShareSheet = false
  #endif

  private struct PlaceholderText {
    static let authURL = "Admin portal auth URL"
    static let apiURL = "Control plane WebSocket URL"
    static let logFilter = "RUST_LOG-style filter string"
    static let accountSlug = "Account slug or ID (optional)"
  }

  private struct FootnoteText {
    static let forAdvanced = try? AttributedString(
      markdown: """
        **WARNING:** These settings are intended for internal debug purposes **only**. \
        Changing these will disrupt access to your Firezone resources.
        """
    )
  }

  public init(store: Store) {
    self.store = store
    self.configuration = store.configuration
    _viewModel = StateObject(
      wrappedValue: SettingsViewModel(configuration: store.configuration, store: store))
  }

  public var body: some View {
    settingsContent
  }

  private var settingsContent: some View {
    splitView
      .onChange(of: focusedField) { [oldField = focusedField] newField in
        guard let field = oldField, field != newField else { return }
        withErrorHandler { try await viewModel.saveField(field) }
      }
      .alert(
        "Sign out required",
        isPresented: $viewModel.showSignOutConfirmation,
        actions: {
          Button("Cancel", role: .cancel) {
            viewModel.cancelSignOutChange()
          }
          Button("Sign Out") {
            withErrorHandler {
              try await viewModel.confirmSignOutChange()
            }
          }
        },
        message: {
          Text("Changing this setting will sign you out. Do you want to continue?")
        }
      )
  }

  private var splitView: some View {
    NavigationSplitView(columnVisibility: .constant(.all)) {
      List(selection: $localSelectedSection) {
        ForEach(SettingsSection.allCases) { section in
          Label(section.rawValue, systemImage: section.icon)
            .badge(section == .advanced && !viewModel.isValid ? "!" : nil)
            .tag(section)
        }
      }
      .listStyle(.sidebar)
      .navigationTitle("Settings")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
          ToolbarItem(placement: .navigationBarTrailing) {
            Button("Done") { dismiss() }
          }
        }
      #endif
    } detail: {
      settingsDetailView(for: localSelectedSection ?? .general)
    }
    #if os(macOS)
      .navigationSplitViewColumnWidth(min: 180, ideal: 200, max: 250)
    #endif
  }

  @ViewBuilder
  private func settingsDetailView(for section: SettingsSection) -> some View {
    switch section {
    case .general:
      generalTab
    case .advanced:
      advancedTab
    case .logs:
      logsTab
    case .about:
      AboutView()
    }
  }

  private var generalTab: some View {
    #if os(macOS)
      VStack {
        Spacer()
        HStack {
          Spacer()
          Form {
            HStack {
              Text("Account Slug")
                .frame(width: 150, alignment: .trailing)
              TextField(
                "",
                text: $viewModel.accountSlug,
                prompt: Text(PlaceholderText.accountSlug)
              )
              .focused($focusedField, equals: .accountSlug)
              .disabled(configuration.isAccountSlugForced)
              .frame(width: 250)
            }
            .padding(.bottom, 10)

            Toggle(isOn: $viewModel.connectOnStart) {
              Text("Automatically connect when Firezone is launched")
            }
            .toggleStyle(.checkbox)
            .disabled(configuration.isConnectOnStartForced)
            .onChange(of: viewModel.connectOnStart) { _ in
              withErrorHandler { try await viewModel.saveToggle(.connectOnStart) }
            }

            Toggle(isOn: $viewModel.startOnLogin) {
              Text("Start Firezone when you sign into your Mac")
            }
            .toggleStyle(.checkbox)
            .disabled(configuration.isStartOnLoginForced)
            .onChange(of: viewModel.startOnLogin) { _ in
              withErrorHandler { try await viewModel.saveToggle(.startOnLogin) }
            }
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
              VStack(alignment: .leading, spacing: 2) {
                Text("Account Slug")
                  .foregroundStyle(.secondary)
                  .font(.caption)
                TextField(
                  PlaceholderText.accountSlug,
                  text: $viewModel.accountSlug
                )
                .focused($focusedField, equals: .accountSlug)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.done)
                .disabled(configuration.isAccountSlugForced)
                .padding(.bottom, 10)

                Spacer()

                Toggle(isOn: $viewModel.connectOnStart) {
                  Text("Automatically connect when Firezone is launched")
                }
                .toggleStyle(.switch)
                .disabled(configuration.isConnectOnStartForced)
                .onChange(of: viewModel.connectOnStart) { _ in
                  withErrorHandler { try await viewModel.saveToggle(.connectOnStart) }
                }
              }
            },
            header: { Text("General Settings") },
          )
        }
      }
    #endif
  }

  private var advancedTab: some View {
    #if os(macOS)
      VStack {
        Spacer()

        // Note
        HStack {
          Spacer()
          Text(FootnoteText.forAdvanced ?? "")
            .foregroundStyle(.secondary)
            .frame(width: 400, alignment: .trailing)
          Spacer()
        }

        Spacer()

        // Text fields
        HStack {
          Spacer()
          Form {
            validatedField(
              label: "Auth Base URL",
              text: $viewModel.authURL,
              prompt: PlaceholderText.authURL,
              field: .authURL,
              isValid: viewModel.isAuthURLValid,
              isDisabled: configuration.isAuthURLForced,
              errorMessage: "Must be a valid http:// or https:// URL with no path"
            )

            validatedField(
              label: "API URL",
              text: $viewModel.apiURL,
              prompt: PlaceholderText.apiURL,
              field: .apiURL,
              isValid: viewModel.isApiURLValid,
              isDisabled: configuration.isApiURLForced,
              errorMessage: "Must be a valid wss:// or ws:// URL with no path"
            )

            validatedField(
              label: "Log Filter",
              text: $viewModel.logFilter,
              prompt: PlaceholderText.logFilter,
              field: .logFilter,
              isValid: viewModel.isLogFilterValid,
              isDisabled: configuration.isLogFilterForced,
              errorMessage: "Must not be empty"
            )
          }
          .frame(width: 500)
          Spacer()
        }

        HStack {
          Spacer()
          Button("Reset to Defaults") {
            viewModel.reset()
          }
          .disabled(viewModel.shouldDisableResetButton)
          Spacer()
        }
        .padding(.top, 10)

        Spacer()
      }
    #elseif os(iOS)
      VStack {
        Form {
          Section(
            content: {
              iOSValidatedField(
                label: "Auth Base URL",
                placeholder: PlaceholderText.authURL,
                text: $viewModel.authURL,
                field: .authURL,
                isValid: viewModel.isAuthURLValid,
                isDisabled: configuration.isAuthURLForced
              )
              iOSValidatedField(
                label: "API URL",
                placeholder: PlaceholderText.apiURL,
                text: $viewModel.apiURL,
                field: .apiURL,
                isValid: viewModel.isApiURLValid,
                isDisabled: configuration.isApiURLForced
              )
              iOSValidatedField(
                label: "Log Filter",
                placeholder: PlaceholderText.logFilter,
                text: $viewModel.logFilter,
                field: .logFilter,
                isValid: viewModel.isLogFilterValid,
                isDisabled: configuration.isLogFilterForced
              )
              HStack {
                Spacer()
                Button(
                  "Reset to Defaults",
                  action: {
                    viewModel.reset()
                  }
                )
                .disabled(viewModel.shouldDisableResetButton)
                Spacer()
              }
            },
            header: { Text("Advanced Settings") },
            footer: { Text(FootnoteText.forAdvanced ?? "") }
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
                  Task.detached(priority: .background) {
                    let archiveURL = try LogExporter.tempFile()
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

  #if os(macOS)
    private func exportLogsWithSavePanelOnMac() {
      self.isExportingLogs = true

      let savePanel = NSSavePanel()
      savePanel.prompt = "Save"
      savePanel.nameFieldLabel = "Save log archive to:"
      let fileName = "firezone_logs_\(LogExporter.now()).zip"

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
            guard let session = try store.manager().session() else {
              throw VPNConfigurationManagerError.managerNotInitialized
            }
            try await LogExporter.export(
              to: destinationURL,
              session: session
            )

            window.contentViewController?.presentingViewController?.dismiss(self)
          } catch {
            if let error = error as? IPCClient.Error,
              case IPCClient.Error.noIPCData = error
            {
              Log.warning(
                "\(#function): Error exporting logs: \(error). Is the XPC service running?")
            } else {
              Log.error(error)
            }

            MacOSAlert.show(for: error)
          }

          self.isExportingLogs = false
        }
      }
    }
  #endif

  private func refreshLogSize() {
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

  private func cancelRefreshLogSize() {
    self.calculateLogSizeTask?.cancel()
  }

  private func clearLogFiles() {
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
  private func calculateLogDirSize() async -> String {
    Log.log("\(#function)")

    guard let logFilesFolderURL = SharedAccess.logFolderURL else {
      return "Unknown"
    }

    let logFolderSize = await Log.size(of: logFilesFolderURL)

    do {
      #if os(macOS)
        guard let session = try store.manager().session() else {
          throw VPNConfigurationManagerError.managerNotInitialized
        }
        let providerLogFolderSize = try await IPCClient.getLogFolderSize(session: session)
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
        case IPCClient.Error.noIPCData = error
      {
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
  private func clearAllLogs() async throws {
    Log.log("\(#function)")

    try Log.clear(in: SharedAccess.logFolderURL)

    #if os(macOS)
      try await store.clearLogs()
    #endif
  }

  private func withErrorHandler(action: @escaping () async throws -> Void) {
    Task {
      do {
        try await action()
      } catch {
        Log.error(error)
        #if os(iOS)
          errorHandler.handle(ErrorAlert(title: "Error performing action", error: error))
        #elseif os(macOS)
          MacOSAlert.show(for: error)
        #endif
      }
    }
  }

  // MARK: - Validated field helpers

  #if os(macOS)
    @ViewBuilder
    private func validatedField(
      label: String,
      text: Binding<String>,
      prompt: String,
      field: SettingsField,
      isValid: Bool,
      isDisabled: Bool,
      errorMessage: String
    ) -> some View {
      VStack(alignment: .leading, spacing: 2) {
        HStack {
          Text(label)
            .frame(width: 150, alignment: .trailing)
          TextField("", text: text, prompt: Text(prompt))
            .focused($focusedField, equals: field)
            .disabled(isDisabled)
            .frame(width: 250)
            .validationBorder(isValid: isValid, isFocused: focusedField == field)
        }
        HStack(spacing: 0) {
          Spacer()
            .frame(width: 158)
          Text(errorMessage)
            .font(.caption)
            .foregroundStyle(.red)
            .opacity(!isValid && focusedField != field ? 1 : 0)
        }
      }
    }
  #endif

  #if os(iOS)
    @ViewBuilder
    private func iOSValidatedField(
      label: String,
      placeholder: String,
      text: Binding<String>,
      field: SettingsField,
      isValid: Bool,
      isDisabled: Bool
    ) -> some View {
      VStack(alignment: .leading, spacing: 2) {
        Text(label)
          .foregroundStyle(.secondary)
          .font(.caption)
        TextField(placeholder, text: text)
          .focused($focusedField, equals: field)
          .autocorrectionDisabled()
          .textInputAutocapitalization(.never)
          .submitLabel(.done)
          .disabled(isDisabled)
          .validationBorder(isValid: isValid, isFocused: focusedField == field)
      }
    }
  #endif
}

extension View {
  fileprivate func validationBorder(isValid: Bool, isFocused: Bool) -> some View {
    overlay(
      RoundedRectangle(cornerRadius: 4)
        .stroke(!isValid && !isFocused ? Color.red : Color.clear, lineWidth: 1)
    )
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
