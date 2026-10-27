//
//  SettingsView.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

// TODO: Refactor to fix file length

import Combine
import OSLog
import SwiftUI

// TODO: Move business logic to ViewModel to remove dependency on Store and fix body length
public struct SettingsView: View {
  @StateObject private var viewModel: SettingsViewModel
  @Environment(\.dismiss) var dismiss
  @EnvironmentObject var errorHandler: GlobalErrorHandler

  private let store: Store
  private let configuration: Configuration

  private enum Field: Hashable {
    case accountSlug
    case authURL
    case apiURL
    case logFilter
  }

  @FocusState private var focusedField: Field?
  @State private var isShowingSignOutAlert = false
  @State private var dismissesAfterSignOutAlert = false
  @State private var isConfirmingReset = false

  #if os(iOS)
    private struct LogArchive: Identifiable {
      let url: URL
      var id: URL { url }
    }

    @State private var exportedLogArchive: LogArchive?
  #endif

  #if os(macOS)
    private static let paneWidth: CGFloat = 500
  #endif

  private struct PlaceholderText {
    static let authURL = "Admin portal auth URL"
    static let apiURL = "Control plane WebSocket URL"
    static let logFilter = "RUST_LOG-style filter string"
    static let accountSlug = "Account slug or ID (optional)"
  }

  private enum SignOutAlert {
    static let title = "Takes effect after sign-out"
    static let message =
      "Changes to the account slug or portal only take effect after you sign out and sign in again."
  }

  /// The tabs of the settings screen.
  public enum Tab: Hashable {
    case general
    case deviceTrust
    case logs

    var title: String {
      switch self {
      case .general: return "Settings"
      case .deviceTrust: return "Device Trust"
      case .logs: return "Diagnostics"
      }
    }

    #if os(macOS)
      var systemImage: String {
        switch self {
        case .general: return "gearshape"
        case .deviceTrust: return "checkmark.shield"
        case .logs: return "stethoscope"
        }
      }
    #endif
  }

  public init(store: Store, selectedTab: Tab = .general) {
    self.store = store
    self.configuration = store.configuration
    _viewModel = StateObject(
      wrappedValue: SettingsViewModel(store: store, selectedTab: selectedTab))
  }

  public var body: some View {
    content
      .onChange(of: focusedField) { _ in commitTextFields() }
      .onChange(of: viewModel.portal) { _ in commit(.general) }
      .onChange(of: viewModel.connectOnStart) { _ in commit(.general) }
      .onChange(of: viewModel.startOnLogin) { _ in commit(.general) }
      .onDisappear {
        commitTextFields()
        viewModel.discardInvalidDrafts()
      }
      .alert(SignOutAlert.title, isPresented: $isShowingSignOutAlert) {
        Button("OK") {
          if dismissesAfterSignOutAlert { dismiss() }
        }
      } message: {
        Text(SignOutAlert.message)
      }
  }

  @ViewBuilder
  private var content: some View {
    #if os(iOS)
      NavigationView {
        ZStack {
          Color(UIColor.systemGroupedBackground)
            .ignoresSafeArea()

          VStack {
            TabView(selection: $viewModel.selectedTab) {
              generalTab
                .tabItem {
                  Image(systemName: "slider.horizontal.3")
                  Text(Tab.general.title)
                }
                .badge(viewModel.areURLsValid() ? nil : "!")
                .tag(Tab.general)
              if store.deviceTrustCertificateSummary != nil {
                deviceTrustTab
                  .tabItem {
                    Image(systemName: "rosette")
                    Text(Tab.deviceTrust.title)
                  }
                  .tag(Tab.deviceTrust)
              }
              logsTab
                .tabItem {
                  Image(systemName: "doc.text")
                  Text(Tab.logs.title)
                }
                .badge(viewModel.isLogFilterValid() ? nil : "!")
                .tag(Tab.logs)
            }
          }
          .padding(.bottom, 10)
          .toolbar {
            ToolbarItem(placement: .confirmationAction) {
              Button("Done") { commit(.general, .logs, thenDismiss: true) }
            }
          }
          .navigationTitle(viewModel.selectedTab.title)
          .navigationBarTitleDisplayMode(.inline)
        }
      }
    #elseif os(macOS)
      TabView(selection: $viewModel.selectedTab) {
        generalTab
          .tabItem { Label(Tab.general.title, systemImage: Tab.general.systemImage) }
          .tag(Tab.general)
        if store.deviceTrustCertificateSummary != nil {
          deviceTrustTab
            .tabItem { Label(Tab.deviceTrust.title, systemImage: Tab.deviceTrust.systemImage) }
            .tag(Tab.deviceTrust)
        }
        logsTab
          .tabItem { Label(Tab.logs.title, systemImage: Tab.logs.systemImage) }
          .tag(Tab.logs)
      }
    #else
      #error("Unsupported platform")
    #endif
  }

  private var portalSelection: Binding<Portal> {
    Binding(
      get: { viewModel.portal },
      set: { viewModel.selectPortal($0) }
    )
  }

  private var generalTab: some View {
    #if os(macOS)
      VStack(spacing: 0) {
        Form {
          Section("Sign-in") {
            TextField(
              "Account Slug",
              text: $viewModel.accountSlug,
              prompt: Text(PlaceholderText.accountSlug)
            )
            .focused($focusedField, equals: .accountSlug)
            .onSubmit { commit(.general) }
            .disabled(configuration.isAccountSlugForced)

            Picker(Portal.pickerTitle, selection: portalSelection) {
              ForEach(Portal.allCases) { portal in
                Text(portal.title).tag(portal)
              }
            }
            .disabled(viewModel.isPortalForced)

            if viewModel.portal == .custom {
              TextField(
                "Auth URL",
                text: $viewModel.authURL,
                prompt: Text(PlaceholderText.authURL)
              )
              .focused($focusedField, equals: .authURL)
              .onSubmit { commit(.general) }
              .disabled(configuration.isAuthURLForced)
              errorText(viewModel.authURLError)

              TextField(
                "API URL",
                text: $viewModel.apiURL,
                prompt: Text(PlaceholderText.apiURL)
              )
              .focused($focusedField, equals: .apiURL)
              .onSubmit { commit(.general) }
              .disabled(configuration.isApiURLForced)
              errorText(viewModel.apiURLError)
            }
          }

          Section("Startup") {
            Toggle(isOn: $viewModel.connectOnStart) {
              Text("Automatically connect when Firezone is launched")
            }
            .toggleStyle(.switch)
            .disabled(configuration.isConnectOnStartForced)

            Toggle(isOn: $viewModel.startOnLogin) {
              Text("Start Firezone when you sign into your Mac")
            }
            .toggleStyle(.switch)
            .disabled(configuration.isStartOnLoginForced)
          }
        }
        .formStyle(.grouped)

        paneFooter
      }
      .frame(width: Self.paneWidth)
    #elseif os(iOS)
      VStack {
        Form {
          Section("Sign-in") {
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
              .focused($focusedField, equals: .accountSlug)
              .onSubmit { commit(.general) }
              .disabled(configuration.isAccountSlugForced)
            }

            // A menu rather than a form picker, so the choice sits under its caption like
            // the other fields instead of being pushed to a second, indented line.
            VStack(alignment: .leading, spacing: 2) {
              Text(Portal.pickerTitle)
                .foregroundStyle(.secondary)
                .font(.caption)
              Menu {
                Picker(Portal.pickerTitle, selection: portalSelection) {
                  ForEach(Portal.allCases) { portal in
                    Text(portal.title).tag(portal)
                  }
                }
              } label: {
                HStack(spacing: 4) {
                  Text(viewModel.portal.title)
                  Image(systemName: "chevron.up.chevron.down")
                    .font(.footnote)
                }
              }
              .accessibilityLabel(Portal.pickerTitle)
              .accessibilityValue(viewModel.portal.title)
              .disabled(viewModel.isPortalForced)
            }

            if viewModel.portal == .custom {
              VStack(alignment: .leading, spacing: 2) {
                Text("Auth URL")
                  .foregroundStyle(.secondary)
                  .font(.caption)
                TextField(
                  PlaceholderText.authURL,
                  text: $viewModel.authURL
                )
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.done)
                .focused($focusedField, equals: .authURL)
                .onSubmit { commit(.general) }
                .disabled(configuration.isAuthURLForced)
                errorText(viewModel.authURLError)
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
                .focused($focusedField, equals: .apiURL)
                .onSubmit { commit(.general) }
                .disabled(configuration.isApiURLForced)
                errorText(viewModel.apiURLError)
              }
            }
          }
          Section("Startup") {
            Toggle(isOn: $viewModel.connectOnStart) {
              Text("Automatically connect when Firezone is launched")
            }
            .toggleStyle(.switch)
            .disabled(configuration.isConnectOnStartForced)
          }
          Section {
            HStack {
              Spacer()
              resetButton
              Spacer()
            }
          }
        }
      }
      .background(Color(uiColor: .secondarySystemBackground))
    #endif
  }

  private var logsTab: some View {
    #if os(iOS)
      VStack {
        Form {
          Section(header: Text("Logs")) {
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
              .focused($focusedField, equals: .logFilter)
              .onSubmit { commit(.logs) }
              .disabled(configuration.isLogFilterForced)
              errorText(viewModel.logFilterError)
            }
            LogFilesView(
              sizeText: viewModel.logDirectorySizeText,
              isExporting: viewModel.isExportingLogs,
              isClearing: viewModel.isClearingLogs,
              export: {
                viewModel.isExportingLogs = true
                Task {
                  do {
                    let archiveURL = try await store.exportLogs()
                    self.exportedLogArchive = LogArchive(url: archiveURL)
                  } catch {
                    Log.error(error)
                    viewModel.isExportingLogs = false
                  }
                }
              },
              clear: {
                viewModel.clearLogs()
              }
            )
            .onAppear {
              viewModel.refreshLogDirectorySize()
            }
            .onDisappear {
              viewModel.cancelLogDirectorySizeRefresh()
            }
            .sheet(
              item: $exportedLogArchive,
              onDismiss: {
                viewModel.isExportingLogs = false
              },
              content: { archive in
                ShareSheetView(
                  localFileURL: archive.url,
                  completionHandler: {
                    self.exportedLogArchive = nil
                  }
                )
              }
            )
          }
          Section("About") {
            HStack {
              Text("Version")
                .foregroundStyle(.secondary)
                .font(.caption)
              Spacer()
              if let commitURL = BundleHelper.commitURL {
                Link(BundleHelper.versionDescription, destination: commitURL)
              } else {
                Text(BundleHelper.versionDescription)
              }
            }
            .contextMenu {
              Button("Copy") { UIPasteboard.general.string = BundleHelper.versionDescription }
            }
          }
        }
      }
    #elseif os(macOS)
      VStack(spacing: 0) {
        Form {
          Section("Logs") {
            TextField(
              "Log Filter",
              text: $viewModel.logFilter,
              prompt: Text(PlaceholderText.logFilter)
            )
            .focused($focusedField, equals: .logFilter)
            .onSubmit { commit(.logs) }
            .disabled(configuration.isLogFilterForced)
            errorText(viewModel.logFilterError)

            LogFilesView(
              sizeText: viewModel.logDirectorySizeText,
              isExporting: viewModel.isExportingLogs,
              isClearing: viewModel.isClearingLogs,
              export: {
                self.exportLogsWithSavePanelOnMac()
              },
              clear: {
                viewModel.clearLogs()
              }
            )
            .onAppear {
              viewModel.refreshLogDirectorySize()
            }
            .onDisappear {
              viewModel.cancelLogDirectorySizeRefresh()
            }
          }
        }
        .formStyle(.grouped)

        paneFooter
      }
      .frame(width: Self.paneWidth)
    #else
      #error("Unsupported platform")
    #endif
  }

  @ViewBuilder
  private var deviceTrustTab: some View {
    #if os(macOS)
      ScrollView {
        HStack {
          Spacer()
          if let summary = store.deviceTrustCertificateSummary {
            DeviceTrustSettingsView(summary: summary)
              .frame(maxWidth: 600)
          }
          Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical)
      }
      .frame(width: Self.paneWidth, height: 400)
    #elseif os(iOS)
      if let summary = store.deviceTrustCertificateSummary {
        DeviceTrustSettingsView(summary: summary)
      }
    #else
      #error("Unsupported platform")
    #endif
  }

  @ViewBuilder
  private func errorText(_ error: String?) -> some View {
    if let error {
      Text(error)
        .font(.caption)
        .foregroundStyle(.red)
    }
  }

  private var resetButton: some View {
    Button("Reset to Defaults") { isConfirmingReset = true }
      .disabled(viewModel.shouldDisableResetButton)
      .alert("Reset settings to defaults?", isPresented: $isConfirmingReset) {
        Button("Reset", role: .destructive) {
          viewModel.reset()
          commit(viewModel.selectedTab)
        }
        Button("Cancel", role: .cancel) {}
      }
  }

  /// Saves the settings of `tabs`, and says so when a change waits for the next sign-in.
  private func commit(_ tabs: Tab..., thenDismiss: Bool = false) {
    // Read now: the commit from `onDisappear` runs once the view is gone.
    let viewModel = viewModel

    withErrorHandler {
      var changedSignIn = false
      for tab in tabs {
        let changed = try await viewModel.save(tab)
        changedSignIn = changedSignIn || changed
      }

      if changedSignIn, [.connected, .connecting, .reasserting].contains(store.vpnStatus) {
        dismissesAfterSignOutAlert = thenDismiss
        isShowingSignOutAlert = true
      } else if thenDismiss {
        dismiss()
      }
    }
  }

  private func commitTextFields() {
    commit(.general, .logs)
  }

  #if os(macOS)
    private var paneFooter: some View {
      HStack {
        Spacer()
        resetButton
      }
      .padding([.horizontal, .bottom], 20)
    }

    private func exportLogsWithSavePanelOnMac() {
      viewModel.isExportingLogs = true

      let savePanel = NSSavePanel()
      savePanel.prompt = "Save"
      savePanel.nameFieldLabel = "Save log archive to:"
      savePanel.nameFieldStringValue = viewModel.logArchiveFileName()

      guard let window = NSApp.keyWindow else {
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
    Button(action: action) {
      if isProcessing {
        ProgressView().controlSize(.small)
          .frame(width: 16, height: 16)
      } else {
        Image(systemName: systemImageName)
          .frame(width: 16, height: 16)
      }
    }
    // Inside a Form row, any other style makes a tap anywhere on the row fire every button in it.
    .buttonStyle(.borderless)
    .disabled(isProcessing)
    .accessibilityLabel(title)
    .help(title)
  }
}

struct LogFilesView: View {
  /// nil while the size is being computed.
  let sizeText: String?
  let isExporting: Bool
  let isClearing: Bool
  let export: () -> Void
  let clear: () -> Void

  var body: some View {
    #if os(macOS)
      LabeledContent("Log Files") {
        controls
      }
    #elseif os(iOS)
      HStack {
        Text("Log Files")
          .foregroundStyle(.secondary)
          .font(.caption)
        Spacer()
        controls
      }
    #endif
  }

  private var controls: some View {
    HStack(spacing: 12) {
      if let sizeText {
        Text(sizeText)
          .foregroundStyle(.secondary)
      } else {
        ProgressView().controlSize(.small)
          .frame(width: 16, height: 16)
      }
      ButtonWithProgress(
        systemImageName: "arrow.up.doc",
        title: "Export Logs",
        isProcessing: isExporting,
        action: export
      )
      ButtonWithProgress(
        systemImageName: "trash",
        title: "Clear Log Directory",
        isProcessing: isClearing,
        action: clear
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
