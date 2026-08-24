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
    case loaded(X509CertificateSummary, keyProblem: String?)
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

      case .loaded(let summary, let keyProblem):
        details(summary, keyProblem: keyProblem)
      }
    }
    .onAppear { Task { await reload() } }
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Certificate")
        .font(.headline)
      if let explainer {
        Text(explainer)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  /// One line on what the certificate is for, absent while the keychain is still being read.
  ///
  /// The wording is shared across the clients.
  private var explainer: String? {
    switch loadState {
    case .loading:
      return nil
    case .loaded(let summary, let keyProblem)
    where summary.unusableSummary == nil && keyProblem == nil:
      return "Firezone uses this certificate to identify this device."
    case .loaded, .notConfigured, .failed:
      return "Firezone did not find a certificate to identify this device."
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

  private func details(_ summary: X509CertificateSummary, keyProblem: String?) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      if let unusableSummary = summary.unusableSummary {
        notice(
          "Firezone will not present this certificate",
          "It cannot be used to prove this device is enrolled: \(unusableSummary)."
        )
      }

      if let keyProblem {
        notice("Firezone cannot use the certificate's private key", keyProblem)
      }

      Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
        ForEach(summary.fields, id: \.self) { field in
          GridRow {
            Text(field.label)
              .font(.caption)
              .foregroundStyle(.secondary)
            claimValue(field.value)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
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
      let (certificate, keyProblem) = try await Task.detached(priority: .userInitiated) {
        let certificate = try X509Identity.leafCertificate(persistentReference: reference)
        let keyProblem =
          certificate == nil
          ? nil
          : reference.flatMap(X509Identity.privateKeyProblem(persistentReference:))

        return (certificate, keyProblem)
      }.value

      guard let certificate else {
        loadState = .notConfigured

        return
      }

      guard let summary = X509CertificateParser.summary(of: certificate) else {
        loadState = .failed("The certificate could not be parsed.")

        return
      }

      loadState = .loaded(summary, keyProblem: keyProblem)
    } catch {
      Log.error("Failed to read the client certificate: \(error.localizedDescription)")
      loadState = .failed(error.localizedDescription)
    }
  }
}
