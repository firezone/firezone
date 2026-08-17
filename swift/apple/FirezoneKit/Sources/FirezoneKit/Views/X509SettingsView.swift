//
//  X509SettingsView.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import SwiftUI

struct X509SettingsView: View {
  let identityReference: @MainActor () throws -> Data?

  @State private var details: X509IdentityDetails?
  @State private var errorMessage: String?
  @State private var isLoading = true

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(alignment: .firstTextBaseline) {
        VStack(alignment: .leading, spacing: 4) {
          Text("X.509")
            .font(.headline)
          Text(
            "Firezone uses this VPN configuration identity to prove device enrollment when connecting. Private-key bytes never leave the Apple Keychain."
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
        .disabled(isLoading)
      }

      if isLoading {
        HStack {
          Spacer()
          ProgressView("Reading X.509 identity…")
          Spacer()
        }
        .padding()
      } else if let errorMessage {
        VStack(alignment: .leading, spacing: 8) {
          Label("Unable to read the X.509 identity", systemImage: "exclamationmark.triangle")
            .font(.headline)
            .foregroundStyle(.orange)
          Text(errorMessage)
            .font(.callout)
            .textSelection(.enabled)
          Text("Contact your administrator for support.")
            .font(.callout)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
      } else if let details {
        Text(details.summary)
          .font(.callout)
          .foregroundStyle(.secondary)
          .textSelection(.enabled)

        ForEach(Array(details.sections.enumerated()), id: \.offset) { _, section in
          VStack(alignment: .leading, spacing: 8) {
            Text(section.title)
              .font(.headline)

            ForEach(Array(section.fields.enumerated()), id: \.offset) { _, field in
              VStack(alignment: .leading, spacing: 3) {
                Text(field.label)
                  .font(.caption)
                  .foregroundStyle(.secondary)
                Text(field.value)
                  .font(.system(.caption, design: .monospaced))
                  .textSelection(.enabled)
                  .frame(maxWidth: .infinity, alignment: .leading)
              }
              .padding(.vertical, 3)
              Divider()
            }
          }
          .padding()
          .frame(maxWidth: .infinity, alignment: .leading)
          .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
        }
      }
    }
    .padding()
    .task { await reload() }
  }

  @MainActor
  private func reload() async {
    isLoading = true
    errorMessage = nil
    details = nil

    do {
      let persistentReference = try identityReference()
      details = try await Task.detached(priority: .userInitiated) {
        try X509Identity.details(persistentReference: persistentReference)
      }.value
    } catch {
      Log.error("Failed to load X.509 settings diagnostics: \(error.localizedDescription)")
      errorMessage = error.localizedDescription
    }

    isLoading = false
  }
}
