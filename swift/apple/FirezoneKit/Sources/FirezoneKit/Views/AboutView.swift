//
//  AboutView.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import SwiftUI

struct AboutView: View {
  // Apple's continuous corner radius ratio (superellipse) applied to 128pt icon
  private static let iOSIconCornerRadius: CGFloat = 128 * 0.1748

  private var appName: String {
    Bundle.main.infoDictionary?[kCFBundleNameKey as String] as? String ?? "Firezone"
  }

  private var appVersion: String {
    Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "Unknown"
  }

  private var buildVersion: String {
    Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
  }

  private var gitSha: String {
    BundleHelper.gitSha
  }

  private var copyright: String {
    Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String ?? ""
  }

  private var fallbackIcon: some View {
    Image(systemName: "app.fill")
      .resizable()
      .frame(width: 128, height: 128)
      .foregroundStyle(Color.accentColor)
  }

  @ViewBuilder
  private var appIcon: some View {
    #if os(macOS)
      if let nsImage = NSImage(named: "AppIcon") {
        Image(nsImage: nsImage)
          .resizable()
          .frame(width: 128, height: 128)
      } else {
        fallbackIcon
      }
    #elseif os(iOS)
      if let uiImage = UIImage(named: "AppIconDisplay") {
        Image(uiImage: uiImage)
          .resizable()
          .frame(width: 128, height: 128)
          .cornerRadius(Self.iOSIconCornerRadius, antialiased: true)
      } else {
        fallbackIcon
      }
    #endif
  }

  var body: some View {
    VStack(spacing: 16) {
      appIcon

      Text(appName)
        .font(.title)
        .fontWeight(.semibold)

      Text("Version \(appVersion) (\(buildVersion))")
        .font(.body)
        .foregroundStyle(.secondary)

      Text("Build: \(gitSha)")
        .font(.caption)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .padding(.bottom, 8)

      Text(copyright)
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)

      Spacer()
    }
    .padding(32)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}

#Preview {
  AboutView()
}
