//
//  MacOSAlert.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//
//  A helper to display alerts that aim to be actionable by the end-user.

#if os(macOS)
  import SystemExtensions
  import AppKit
  import NetworkExtension

  protocol UserFriendlyError {
    func userMessage() -> String?
  }

  extension NEVPNError: UserFriendlyError {
    func userMessage() -> String? {
      switch code {

      // Code 1
      case .configurationDisabled:
        return """
          The VPN configuration appears to be disabled. Please remove the Firezone
          VPN configuration in System Settings and try again.
          """

      // Code 2
      case .configurationInvalid:
        return """
          The VPN configuration appears to be invalid. Please remove the Firezone
          VPN configuration in System Settings and try again.
          """

      // Code 3
      case .connectionFailed:
        return """
          The VPN connection failed. Try signing in again.
          """

      // Code 4
      case .configurationStale:
        return """
          The VPN configuration appears to be stale. Please remove the Firezone
          VPN configuration in System Settings and try again.
          """

      // Code 5
      case .configurationReadWriteFailed:
        return """
          Could not read or write the VPN configuration. Try removing the Firezone
          VPN configuration from System Settings if this issue persists.
          """

      // Code 6
      case .configurationUnknown:
        return """
          An unknown VPN configuration error occurred. Try removing the Firezone
          VPN configuration from System Settings if this issue persists.
          """

      @unknown default:
        return "\(self)"
      }
    }
  }

  extension OSSystemExtensionError: UserFriendlyError {
    func userMessage() -> String? {
      switch code {

      // Code 1
      case .unknown:
        return """
          An unknown error occurred. Please try enabling the system extension again.
          If the issue persists, contact your administrator.
          """

      // Code 2
      case .missingEntitlement:
        return """
          The system extension appears to be missing an entitlement. Please try
          downloading and installing Firezone again.
          """

      // Code 3
      case .unsupportedParentBundleLocation:
        return """
          Please ensure Firezone.app is launched from the /Applications folder
          and try again.
          """

      // Code 4
      case .extensionNotFound:
        return """
          The Firezone.app bundle seems corrupt. Please try downloading and
          installing Firezone again.
          """

      // Code 5
      case .extensionMissingIdentifier:
        return """
          The system extension is missing its bundle identifier. Please try
          downloading and installing Firezone again.
          """

      // Code 6
      case .duplicateExtensionIdentifer:
        return """
          The system extension appears to have been installed already. Please try
          completely removing Firezone and all Firezone-related system extensions
          and try again.
          """

      // Code 7
      case .unknownExtensionCategory:
        return """
          The system extension doesn't belong to any recognizable category.
          Please contact your administrator for assistance.
          """

      // Code 8
      case .codeSignatureInvalid:
        return """
          The system extension contains an invalid code signature. Please ensure
          your macOS version is up to date and system integrity protection (SIP)
          is enabled and functioning properly.
          """

      // Code 9
      case .validationFailed:
        return """
          The system extension unexpectedly failed validation. Please try updating
          to the latest version and contact your administrator if this issue
          persists.
          """

      // Code 10
      case .forbiddenBySystemPolicy:
        return """
          The FirezoneNetworkExtension was blocked from loading by a system policy.
          This will prevent Firezone from functioning. Please contact your
          administrator for assistance.

          Team ID: 47R2M6779T
          Extension Identifier: dev.firezone.firezone.network-extension
          """

      // Code 11
      case .requestCanceled:
        // This will happen if the user cancels
        return """
            You must enable the FirezoneNetworkExtension System Extension in System Settings to continue. Until you do,
            all functionality will be disabled.
          """

      // Code 12
      case .requestSuperseded:
        // This will happen if the user repeatedly clicks "Enable ..."
        return """
          You must enable the FirezoneNetworkExtension System Extension in System Settings to continue. Until you do,
          all functionality will be disabled.

          For more information and troubleshooting, please contact your administrator.
          """

      // Code 13
      case .authorizationRequired:
        // This happens the first time we try to install the system extension.
        // The user is prompted but we still get this.
        return nil

      @unknown default:
        return "\(self)"
      }
    }
  }

  // Sometimes errors are passed to us as NSError objects, the Objective-C variant
  extension NSError: UserFriendlyError {
    func userMessage() -> String? {
      switch domain {
      case NEVPNErrorDomain:
        // SAFETY: These are the same error type
        // swiftlint:disable:next force_unwrapping
        let code = NEVPNError.Code(rawValue: self.code)!
        let err = NEVPNError(code)
        return err.userMessage()
      case OSSystemExtensionErrorDomain:
        // SAFETY: These are the same error types
        // swiftlint:disable:next force_unwrapping
        let code = OSSystemExtensionError.Code(rawValue: self.code)!
        let err = OSSystemExtensionError(code)
        return err.userMessage()
      default:
        return "\(self)"
      }
    }
  }

  /// A floating utility panel for displaying alerts in a menu bar app
  /// where no main window exists. This avoids blocking the main thread
  /// with NSAlert.runModal().
  @MainActor
  final class AlertPanel {
    static let shared = AlertPanel()

    private static let menuBarOffset: CGFloat = 100

    private var pendingAlertCount = 0

    private lazy var panel: NSPanel = {
      // Create a minimal panel to host sheets - behaves like a modal alert
      let panel = NSPanel(
        contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
        styleMask: [.titled, .closable],
        backing: .buffered,
        defer: true
      )
      // Modal panel level ensures it stays above other windows
      panel.level = .modalPanel
      panel.isReleasedWhenClosed = false
      panel.hidesOnDeactivate = false
      // Make transparent so only the sheet is visible
      panel.isOpaque = false
      panel.backgroundColor = .clear
      panel.title = ""
      return panel
    }()

    private init() {}

    func showAlert(
      _ alert: NSAlert,
      completion: ((NSApplication.ModalResponse) -> Void)? = nil
    ) {
      // Position panel at top-center of main screen
      if let screen = NSScreen.main {
        let screenFrame = screen.visibleFrame
        let panelX = screenFrame.midX - panel.frame.width / 2
        let panelY = screenFrame.maxY - Self.menuBarOffset
        panel.setFrameOrigin(NSPoint(x: panelX, y: panelY))
      }

      pendingAlertCount += 1

      if pendingAlertCount == 1 {
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
      }

      alert.beginSheetModal(for: panel) { [weak self] response in
        // AppKit may invoke this on an arbitrary thread, so dispatch back to MainActor
        Task { @MainActor in
          completion?(response)
          self?.pendingAlertCount -= 1
          if self?.pendingAlertCount == 0 {
            self?.panel.orderOut(nil)
          }
        }
      }
    }

    func showAlert(_ alert: NSAlert) async -> NSApplication.ModalResponse {
      await withCheckedContinuation { continuation in
        showAlert(alert) { response in
          continuation.resume(returning: response)
        }
      }
    }
  }

  // MARK: - MacOSAlert

  @MainActor
  public struct MacOSAlert {
    /// Ensures the alert has the app icon set for consistent branding.
    private static func applyDefaultStyle(_ alert: NSAlert) {
      alert.icon = NSApp.applicationIconImage
    }

    /// Shows an alert non-blockingly. Uses a sheet if a window is available,
    /// otherwise uses a floating panel.
    public static func show(_ alert: NSAlert) {
      Task {
        _ = await show(alert)
      }
    }

    /// Shows an alert and waits for the user's response.
    /// Always uses AlertPanel for consistent behavior in menu bar apps.
    public static func show(_ alert: NSAlert) async -> NSApplication.ModalResponse {
      applyDefaultStyle(alert)
      return await AlertPanel.shared.showAlert(alert)
    }

    /// Shows an error alert with a user-friendly message.
    public static func show(for error: Error) {
      let message = (error as UserFriendlyError).userMessage() ?? "\(error)"
      let alert = NSAlert()

      alert.messageText = "An error occurred."
      alert.informativeText = message
      alert.alertStyle = .critical

      show(alert)
    }
  }

#endif
