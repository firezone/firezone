//
//  SettingsView.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

// TODO: Refactor to fix file length

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

// TODO: Move business logic to ViewModel to remove dependency on Store and fix body length
public struct SettingsView: View {
  @StateObject private var viewModel: SettingsViewModel
  @Environment(\.dismiss) var dismiss
  @EnvironmentObject var errorHandler: GlobalErrorHandler

  private let store: Store
  private let configuration: Configuration

  private enum ConfirmationAlertContinueAction: Int {
    case none
    case saveSettings
    case saveAllSettingsAndDismiss

    func performAction(on view: SettingsView) async throws {
      switch self {
      case .none:
        break
      case .saveSettings:
        try await view.saveSettings()
      case .saveAllSettingsAndDismiss:
        try await view.saveAllSettingsAndDismiss()
      }
    }
  }

  @State private var isShowingConfirmationAlert = false
  @State private var confirmationAlertContinueAction: ConfirmationAlertContinueAction = .none

  @State private var selectedTab: Tab

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

  /// The tabs of the settings screen.
  public enum Tab: Hashable {
    case general
    case advanced
    case x509
    case logs
  }

  public init(store: Store, selectedTab: Tab = .general) {
    self.store = store
    self.configuration = store.configuration
    _viewModel = StateObject(wrappedValue: SettingsViewModel(store: store))
    _selectedTab = State(initialValue: selectedTab)
  }

  public var body: some View {
    #if os(iOS)
      NavigationView {
        ZStack {
          Color(UIColor.systemGroupedBackground)
            .ignoresSafeArea()

          VStack {
            TabView(selection: $selectedTab) {
              generalTab
                .tabItem {
                  Image(systemName: "slider.horizontal.3")
                  Text("General")
                }
                .tag(Tab.general)
              advancedTab
                .tabItem {
                  Image(systemName: "gearshape.2")
                  Text("Advanced")
                }
                .badge(viewModel.isValid() ? nil : "!")
                .tag(Tab.advanced)
              if store.x509CertificateSummary != nil {
                certificateTab
                  .tabItem {
                    Image(systemName: "rosette")
                    Text("Device Trust")
                  }
                  .tag(Tab.x509)
              }
              logsTab
                .tabItem {
                  Image(systemName: "doc.text")
                  Text("Diagnostic Logs")
                }
                .tag(Tab.logs)
            }
          }
          .padding(.bottom, 10)
          .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
              Button("Save") {
                let action = ConfirmationAlertContinueAction.saveAllSettingsAndDismiss
                if case .connected = store.vpnStatus {
                  self.confirmationAlertContinueAction = action
                  self.isShowingConfirmationAlert = true
                } else {
                  withErrorHandler { try await action.performAction(on: self) }
                }
              }
              .disabled(viewModel.shouldDisableApplyButton)
            }
            ToolbarItem(placement: .navigationBarLeading) {
              Button("Cancel") { dismiss() }
            }
          }
          .navigationTitle("Settings")
          .navigationBarTitleDisplayMode(.inline)
          .alert(
            "Some settings may not have been applied",
            isPresented: $isShowingConfirmationAlert,
            presenting: confirmationAlertContinueAction,
            actions: { confirmationAlertContinueAction in
              Button("OK") {
                withErrorHandler {
                  try await confirmationAlertContinueAction.performAction(on: self)
                }
              }
            },
            message: { _ in
              Text("Some settings require signing out and in again before they take effect.")
            }
          )
        }
      }
    #elseif os(macOS)
      VStack {
        TabView(selection: $selectedTab) {
          generalTab
            .tabItem {
              Text("General")
            }
            .tag(Tab.general)
          advancedTab
            .tabItem {
              Text("Advanced")
            }
            .tag(Tab.advanced)
          if store.x509CertificateSummary != nil {
            certificateTab
              .tabItem {
                Text("Device Trust")
              }
              .tag(Tab.x509)
          }
          logsTab
            .tabItem {
              Text("Diagnostic Logs")
            }
            .tag(Tab.logs)
        }
        .padding(20)
        Spacer()
        HStack(spacing: 5) {
          Text("Build: \(BundleHelper.gitSha)")
            .textSelection(.enabled)
            .foregroundColor(.gray)
          Spacer()
          Button(
            "Reset to Defaults",
            action: {
              viewModel.reset()
            }
          )
          .disabled(viewModel.shouldDisableResetButton)

          Button(
            "Apply",
            action: {
              let action = ConfirmationAlertContinueAction.saveSettings
              if [.connected, .connecting, .reasserting].contains(store.vpnStatus) {
                self.confirmationAlertContinueAction = action
                self.isShowingConfirmationAlert = true
              } else {
                withErrorHandler { try await action.performAction(on: self) }
              }
            }
          )
          .disabled(viewModel.shouldDisableApplyButton)

        }
        .padding([.bottom], 20)
        .padding([.leading, .trailing], 40)
        Spacer()
      }
      .alert(
        "Some settings may not have been applied",
        isPresented: $isShowingConfirmationAlert,
        presenting: confirmationAlertContinueAction,
        actions: { confirmationAlertContinueAction in
          Button("OK", role: .destructive) {
            withErrorHandler { try await confirmationAlertContinueAction.performAction(on: self) }
          }
        },
        message: { _ in
          Text("Some settings require signing out and in again before they take effect.")
        }
      )
    #else
      #error("Unsupported platform")
    #endif
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
              .disabled(configuration.isAccountSlugForced)
              .frame(width: 250)
            }
            .padding(.bottom, 10)

            Toggle(isOn: $viewModel.connectOnStart) {
              Text("Automatically connect when Firezone is launched")
            }
            .toggleStyle(.checkbox)
            .disabled(configuration.isConnectOnStartForced)

            Toggle(isOn: $viewModel.startOnLogin) {
              Text("Start Firezone when you sign into your Mac")
            }
            .toggleStyle(.checkbox)
            .disabled(configuration.isStartOnLoginForced)
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
      ScrollView {
        VStack(spacing: 24) {
          // Note
          HStack {
            Spacer()
            Text(FootnoteText.forAdvanced ?? "")
              .foregroundStyle(.secondary)
              .frame(width: 400, alignment: .trailing)
            Spacer()
          }

          // Text fields
          HStack {
            Spacer()
            Form {
              // Auth Base URL
              HStack {
                Text("Auth Base URL")
                  .frame(width: 150, alignment: .trailing)
                TextField(
                  "",
                  text: $viewModel.authURL,
                  prompt: Text(PlaceholderText.authURL)
                )
                .disabled(configuration.isAuthURLForced)
                .frame(width: 250)
              }

              // API URL
              HStack {
                Text("API URL")
                  .frame(width: 150, alignment: .trailing)
                TextField(
                  "",
                  text: $viewModel.apiURL,
                  prompt: Text(PlaceholderText.apiURL)
                )
                .disabled(configuration.isApiURLForced)
                .frame(width: 250)
              }

              // Log Filter
              HStack {
                Text("Log Filter")
                  .frame(width: 150, alignment: .trailing)
                TextField(
                  "",
                  text: $viewModel.logFilter,
                  prompt: Text(PlaceholderText.logFilter)
                )
                .disabled(configuration.isLogFilterForced)
                .frame(width: 250)
              }
            }
            .frame(width: 500)
            Spacer()
          }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical)
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
                  PlaceholderText.authURL,
                  text: $viewModel.authURL
                )
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.done)
                .disabled(configuration.isAuthURLForced)
              }
              VStack(alignment: .leading, spacing: 2) {
                Text("API URL")
                  .foregroundStyle(.secondary)
                  .font(.caption)
                TextField(
                  PlaceholderText.apiURL,
                  text: $viewModel.apiURL
                )
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.done)
                .disabled(configuration.isApiURLForced)
              }
              VStack(alignment: .leading, spacing: 2) {
                Text("Log Filter")
                  .foregroundStyle(.secondary)
                  .font(.caption)
                TextField(
                  PlaceholderText.logFilter,
                  text: $viewModel.logFilter
                )
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.done)
                .disabled(configuration.isLogFilterForced)
              }
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
        Spacer()
        HStack {
          Text("Build: \(BundleHelper.gitSha)")
            .textSelection(.enabled)
            .foregroundColor(.gray)
          Spacer()
        }
        .padding([.leading, .bottom], 20)
        .background(Color(uiColor: .secondarySystemBackground))
      }
      .background(Color(uiColor: .secondarySystemBackground))
    #endif
  }

  private var logsTab: some View {
    #if os(iOS)
      VStack {
        Form {
          Section(header: Text("Logs")) {
            LogDirectorySizeView(sizeText: viewModel.logDirectorySizeText)
              .onAppear {
                viewModel.refreshLogDirectorySize()
              }
              .onDisappear {
                viewModel.cancelLogDirectorySizeRefresh()
              }
            HStack {
              Spacer()
              ButtonWithProgress(
                systemImageName: "trash",
                title: "Clear Log Directory",
                isProcessing: viewModel.isClearingLogs,
                action: {
                  viewModel.clearLogs()
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
                isProcessing: viewModel.isExportingLogs,
                action: {
                  viewModel.isExportingLogs = true
                  Task {
                    do {
                      let archiveURL = try await store.exportLogs()
                      self.logTempZipFileURL = archiveURL
                      self.isPresentingExportLogShareSheet = true
                    } catch {
                      Log.error(error)
                      viewModel.isExportingLogs = false
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
                      viewModel.isExportingLogs = false
                      self.logTempZipFileURL = nil
                    }
                  )
                  .onDisappear {
                    self.isPresentingExportLogShareSheet = false
                    viewModel.isExportingLogs = false
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
          LogDirectorySizeView(sizeText: viewModel.logDirectorySizeText)
            .onAppear {
              viewModel.refreshLogDirectorySize()
            }
            .onDisappear {
              viewModel.cancelLogDirectorySizeRefresh()
            }
          HStack(spacing: 30) {
            ButtonWithProgress(
              systemImageName: "trash",
              title: "Clear Log Directory",
              isProcessing: viewModel.isClearingLogs,
              action: {
                viewModel.clearLogs()
              }
            )
            ButtonWithProgress(
              systemImageName: "arrow.up.doc",
              title: "Export Logs",
              isProcessing: viewModel.isExportingLogs,
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

  @ViewBuilder
  private var certificateTab: some View {
    #if os(macOS)
      ScrollView {
        HStack {
          Spacer()
          if let summary = store.x509CertificateSummary {
            X509SettingsView(summary: summary)
              .frame(maxWidth: 600)
          }
          Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical)
      }
    #elseif os(iOS)
      if let summary = store.x509CertificateSummary {
        X509SettingsView(summary: summary)
      }
    #else
      #error("Unsupported platform")
    #endif
  }

  private func saveAllSettingsAndDismiss() async throws {
    try await saveSettings()
    dismiss()
  }

  #if os(macOS)
    private func exportLogsWithSavePanelOnMac() {
      viewModel.isExportingLogs = true

      let savePanel = NSSavePanel()
      savePanel.prompt = "Save"
      savePanel.nameFieldLabel = "Save log archive to:"
      savePanel.nameFieldStringValue = viewModel.logArchiveFileName()

      guard
        let window = NSApp.windows.first(where: {
          $0.identifier?.rawValue.hasPrefix("firezone-settings") ?? false
        })
      else {
        viewModel.isExportingLogs = false
        Log.log("Settings window not found. Can't show save panel.")
        return
      }

      savePanel.beginSheetModal(for: window) { response in
        guard response == .OK else {
          viewModel.isExportingLogs = false
          return
        }
        guard let destinationURL = savePanel.url else {
          viewModel.isExportingLogs = false
          return
        }

        Task {
          do {
            try await store.exportLogs(to: destinationURL)

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

          viewModel.isExportingLogs = false
        }
      }
    }
  #endif

  private func saveSettings() async throws {
    try await viewModel.save()
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
}

struct ButtonWithProgress: View {
  let systemImageName: String
  let title: String
  let isProcessing: Bool
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
  /// nil while the size is being computed.
  let sizeText: String?

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
          Text(sizeText ?? "")
        },
        icon: {
          if sizeText == nil {
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
