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

  init(identityReference: @escaping @MainActor @Sendable () throws -> Data?) {
    self.identityReference = identityReference
  }

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
        notice("The client certificate could not be read", message)

      case .loaded(let summary):
        details(summary)
      }
    }
    .onAppear { Task { await reload() } }
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

  /// How the screen says that something is wrong with the certificate.
  private func notice(_ title: String, _ message: String) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Label(title, systemImage: "exclamationmark.triangle")
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
      if let unusableSummary = summary.unusableSummary {
        notice(
          "Firezone will not present this certificate",
          "It cannot be used to prove this device is enrolled: \(unusableSummary)."
        )
      }

      ForEach(summary.fields, id: \.self) { field in
        VStack(alignment: .leading, spacing: 2) {
          Text(field.label)
            .font(.caption)
            .foregroundStyle(.secondary)
          claimValue(field.value)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
    }
  }

  @ViewBuilder
  private func claimValue(_ claim: X509ClaimValue) -> some View {
    switch claim {
    case .present(let value):
      Text(value)
        .font(.system(.caption, design: .monospaced))
        .textSelection(.enabled)

    case .absent:
      Text("Not present")
        .font(.caption)
        .foregroundStyle(.secondary)

    case .invalid(let rejection):
      Label("Ignored: \(rejection.reason)", systemImage: "exclamationmark.triangle")
        .font(.caption)
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
