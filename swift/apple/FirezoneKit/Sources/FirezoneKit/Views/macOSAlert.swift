//
//  macOSAlert.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

#if os(macOS)
import SystemExtensions
import AppKit

@MainActor
struct macOSAlert {
  static func show(for error: OSSystemExtensionError) {
    let messageText: String? =
    switch error.code {

    // Code 1
    case .unknown:
      """
      An unknown error occurred. Please try enabling the system extension again.
      If the issue persists, contact your administrator.
      """

    // Code 2
    case .missingEntitlement:
      """
      The system extension appears to be missing an entitlement. Please try
      downloading and installing Firezone again.
      """

    // Code 3
    case .unsupportedParentBundleLocation:
      """
      Please ensure Firezone.app is launched from the /Applications folder
      and try again.
      """

    // Code 4
    case .extensionNotFound:
      """
      The Firezone.app bundle seems corrupt. Please try downloading and
      installing Firezone again.
      """

    // Code 5
    case .extensionMissingIdentifier:
      """
      The system extension is missing its bundle identifier. Please try
      downloading and installing Firezone again.
      """

    // Code 6
    case .duplicateExtensionIdentifer:
      """
      The system extension appears to have been installed already. Please try
      completely removing Firezone and all Firezone-related system extensions
      and try again.
      """

    // Code 7
    case .unknownExtensionCategory:
      """
      The system extension doesn't belong to any recognizable category.
      Please contact your adminstrator for assistance.
      """

    // Code 8
    case .codeSignatureInvalid:
      """
      The system extension contains an invalid code signature. Please ensure
      your macOS version is up to date and system integrity protection (SIP)
      is enabled and functioning properly.
      """

    // Code 9
    case .validationFailed:
      """
      The system extension unexpectedly failed validation. Please try updating
      to the latest version and contact your administrator if this issue
      persists.
      """

    // Code 10
    case .forbiddenBySystemPolicy:
      """
      The FirezoneNetworkExtension was blocked from loading by a system policy.
      This will prevent Firezone from functioning. Please contact your
      administrator for assistance.

      Team ID: 47R2M6779T
      Extension Identifier: dev.firezone.firezone.network-extension
      """

    // Code 11
    case .requestCanceled:
      // This will happen if the user cancels
      nil

    // Code 12
    case .requestSuperseded:
      // This will happen if the user repeatedly clicks "Enable ..."
      nil

    // Code 13
    case .authorizationRequired:
      // This happens the first time we try to install the system extension.
      // The user is prompted but we still get this.
      nil

    default:
      "\(error)"
    }

    // Only show alert if we have something to tell the user about
    guard let messageText else { return }

    let alert = NSAlert()
    alert.messageText = messageText
    alert.alertStyle = .critical
    let _ = alert.runModal()
  }

  static func show(for error: Error) {
    if let error = error as? OSSystemExtensionError {
      show(for: error)
    }
  }
}

#endif
