//
//  macOSAlert.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//
//  A helper to display alerts that aim to be actionable by the end-user.

#if os(macOS)
import SystemExtensions
import AppKit
import NetworkExtension

@MainActor
struct macOSAlert { // swiftlint:disable:this type_name
  static func show(for error: Error) async {
    guard let message = userMessage(for: error)
    else { return }

    let alert = NSAlert()
    alert.messageText = message
    alert.alertStyle = .critical
    _ = await withCheckedContinuation { continuation in
      continuation.resume(returning: alert.runModal())
    }

  }

  // NEVPNError
  private static func userMessage(for error: NEVPNError) -> String? {
    return {
      switch error.code {

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
        return "\(error)"
      }
    }()
  }

  // OSSystemExtensionError
  // swiftlint:disable:next cyclomatic_complexity function_body_length
  private static func userMessage(for error: OSSystemExtensionError) -> String? {
    return {
      switch error.code {

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
        return nil

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
        return "\(error)"
      }
    }()
  }

  // Error (fallback case)
  private static func userMessage(for error: Error) -> String? {
    return "\(error)"
  }
}

#endif
