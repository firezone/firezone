//
//  X509SettingsView.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import SwiftUI

/// Shows the client certificate the VPN profile references, for support and diagnostics.
struct X509SettingsView: View {
  /// Where the certificate comes from, so that one can be handed in for a screenshot.
  let source: X509CertificateSource

  private enum LoadState {
    case loading
    case notConfigured
    case failed(String)
    case loaded(X509CertificateSummary, keyProblem: String?)
  }

  @State private var loadState: LoadState = .loading

  init(source: X509CertificateSource) {
    self.source = source
  }

  var body: some View {
    #if os(iOS)
      // A phone fits one column, so each field becomes its own form row.
      Form {
        switch loadState {
        case .loading:
          Section {
            ProgressView()
              .frame(maxWidth: .infinity)
          }

        case .notConfigured:
          Section { emptyCard(error: nil) }

        case .failed(let message):
          Section { emptyCard(error: message) }

        case .loaded(let summary, let keyProblem):
          Section { card(summary, keyProblem: keyProblem) }

          Section {
            ForEach(summary.fields, id: \.self) { field in
              VStack(alignment: .leading, spacing: 2) {
                Text(field.label)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                claimValue(field.value)
                fieldProblem(field.problem)
              }
            }
          }
        }
      }
      .onAppear { Task { await reload() } }
    #else
      VStack(alignment: .leading, spacing: 12) {
        switch loadState {
        case .loading:
          ProgressView()

        case .notConfigured:
          emptyCard(error: nil)

        case .failed(let message):
          emptyCard(error: message)

        case .loaded(let summary, let keyProblem):
          card(summary, keyProblem: keyProblem)
          details(summary)
        }
      }
      .onAppear { Task { await reload() } }
    #endif
  }

  /// One line on what the certificate is for, absent while the keychain is still being read.
  ///
  /// The wording is shared across the clients. A certificate that was read and refused says so
  /// rather than reading as one that was never found: the rows below carry the attribute that
  /// makes it unusable.
  private var explainer: String? {
    switch loadState {
    case .loading:
      return nil
    case .loaded(let summary, let keyProblem)
    where summary.isUsable && keyProblem == nil:
      return "Firezone uses this certificate to identify this device."
    case .loaded(let summary, _) where !summary.isUsable:
      return "Firezone cannot use this certificate to identify this device."
    case .loaded, .notConfigured, .failed:
      return "Firezone did not find a certificate to identify this device."
    }
  }

  /// Whether the explainer is the one that says Firezone presents this certificate.
  private var isAttesting: Bool {
    switch loadState {
    case .loaded(let summary, let keyProblem):
      return summary.isUsable && keyProblem == nil
    case .loading, .notConfigured, .failed:
      return false
    }
  }

  /// Identifies the certificate the way a keychain viewer does, before any of the detail.
  private func card(_ summary: X509CertificateSummary, keyProblem: String?) -> some View {
    cardLayout(
      title: title(of: summary),
      subtitle: value("Issuer", of: summary).map { "Issued by \($0)" },
      validity: value("Not After", of: summary).map { "Valid until \($0)" }
    ) {
      // Only the rules no row shows: the rest read underneath the attribute they are about,
      // and repeating them here would say the same thing twice.
      if !summary.certificateProblems.isEmpty {
        notice(
          "Firezone will not present this certificate",
          summary.certificateProblems.map(\.sentence).joined(separator: " ")
        )
      }

      if let keyProblem {
        notice("Firezone cannot use the certificate's private key", keyProblem)
      }
    }
  }

  /// The card when there is nothing to identify: no certificate, or one we could not read.
  private func emptyCard(error: String?) -> some View {
    cardLayout(title: "No client certificate") {
      if let error {
        notice("The client certificate could not be read", error)
      }
    }
  }

  private func cardLayout<Warning: View>(
    title: String,
    subtitle: String? = nil,
    validity: String? = nil,
    @ViewBuilder warning: () -> Warning
  ) -> some View {
    let content = VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .top, spacing: 12) {
        Image(systemName: "rosette")
          .font(.title2)
          .foregroundStyle(.secondary)

        VStack(alignment: .leading, spacing: 2) {
          Text(title)
            .font(.headline)
            .textSelection(.enabled)

          if let subtitle {
            Text(subtitle)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }

          if let validity {
            Text(validity)
              .font(.subheadline)
              .foregroundStyle(.secondary)
              .textSelection(.enabled)
          }
        }
      }

      if let explainer {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
          if isAttesting {
            Image(systemName: "checkmark.circle")
              .foregroundStyle(.tint)
          }

          Text(explainer)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
      }

      warning()
    }
    .frame(maxWidth: .infinity, alignment: .leading)

    #if os(iOS)
      // The section the card sits in already draws its background.
      return content
    #else
      return content.padding(12).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
    #endif
  }

  /// What the card leads with, falling back until something names the certificate.
  private func title(of summary: X509CertificateSummary) -> String {
    value("Common Name", of: summary) ?? value("Subject", of: summary) ?? "Client certificate"
  }

  /// The value of one of the parser's rows, `nil` unless the certificate carries it.
  ///
  /// Rows are looked up by the label the parser gives them.
  private func value(_ label: String, of summary: X509CertificateSummary) -> String? {
    guard let field = summary.fields.first(where: { $0.label == label }),
      case .present(let value) = field.value
    else {
      return nil
    }

    return value
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
    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 8) {
      ForEach(summary.fields, id: \.self) { field in
        GridRow {
          Text(field.label)
            .font(.caption)
            .foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 2) {
            claimValue(field.value)
            fieldProblem(field.problem)
          }
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
        .font(.system(valueTextStyle, design: .monospaced))
        .textSelection(.enabled)

    case .absent:
      Text("Not present")
        .font(.system(valueTextStyle))
        .foregroundStyle(.secondary)
    }
  }

  /// Reads underneath the value it belongs to, the way a form shows an error on its input.
  @ViewBuilder
  private func fieldProblem(_ problem: X509FieldProblem?) -> some View {
    switch problem {
    case .rejected(let rejection):
      Label("Ignored: \(rejection.reason)", systemImage: "exclamationmark.triangle")
        .font(.system(valueTextStyle))

    case .unusable(let reason):
      Label(reason.sentence, systemImage: "exclamationmark.triangle")
        .font(.system(valueTextStyle))
        .foregroundStyle(.red)

    case .none:
      EmptyView()
    }
  }

  /// A phone row gives a value the full width, so it can afford a step up from the grid's caption.
  private var valueTextStyle: Font.TextStyle {
    #if os(iOS)
      .footnote
    #else
      .caption
    #endif
  }

  @MainActor
  private func reload() async {
    loadState = .loading

    do {
      let (certificate, keyProblem) = try await source.read()

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
