//
//  X509SettingsView.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import SwiftUI

/// Shows the client certificate the VPN profile references, for support and diagnostics.
struct X509SettingsView: View {
  /// Reads the persistent keychain reference from the VPN configuration.
  let identityReference: @MainActor @Sendable () throws -> Data?

  private enum LoadState {
    case loading
    case notConfigured
    case failed(String)
    case loaded(X509CertificateSummary)
  }

  @State private var loadState: LoadState = .loading

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      header

      switch loadState {
      case .loading:
        ProgressView()

      case .notConfigured:
        Text("This device has no Firezone client certificate.")
          .font(.callout)
          .foregroundStyle(.secondary)

      case .failed(let message):
        failure(message)

      case .loaded(let summary):
        details(summary)
      }
    }
    .task { await reload() }
  }

  private var header: some View {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 4) {
        Text("Client Certificate")
          .font(.headline)
        Text(
          "Firezone proves this device is enrolled with the certificate your administrator installed. Its private key never leaves the keychain."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      Spacer()

      Button {
        Task { await reload() }
      } label: {
        Label("Refresh", systemImage: "arrow.clockwise")
      }
    }
  }

  private func failure(_ message: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label("The client certificate could not be read", systemImage: "exclamationmark.triangle")
        .font(.callout)
      Text(message)
        .font(.callout)
        .textSelection(.enabled)
      Text("Contact your administrator for support.")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }

  private func details(_ summary: X509CertificateSummary) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if !summary.isCurrentlyValid {
        Label("This certificate is outside its validity period", systemImage: "clock.badge.xmark")
          .font(.callout)
      }

      ForEach(summary.fields, id: \.self) { field in
        VStack(alignment: .leading, spacing: 2) {
          Text(field.label)
            .font(.caption)
            .foregroundStyle(.secondary)
          Text(field.value)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
  }

  @MainActor
  private func reload() async {
    loadState = .loading

    do {
      let reference = try identityReference()
      // Reading the keychain can block, and this runs while the settings window is open.
      let certificate = try await Task.detached(priority: .userInitiated) {
        try X509Identity.leafCertificate(persistentReference: reference)
      }.value

      guard let certificate else {
        loadState = .notConfigured

        return
      }

      guard let summary = X509CertificateParser.summary(of: certificate) else {
        loadState = .failed("The certificate could not be parsed.")

        return
      }

      loadState = .loaded(summary)
    } catch {
      Log.error("Failed to read the client certificate: \(error.localizedDescription)")
      loadState = .failed(error.localizedDescription)
    }
  }
}
