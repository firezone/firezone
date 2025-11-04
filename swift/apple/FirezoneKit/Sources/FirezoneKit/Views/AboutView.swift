// AboutView.swift

import SwiftUI

struct AboutView: View {
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
      .foregroundColor(.accentColor)
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
          .cornerRadius(22.37, antialiased: true)
      } else {
        fallbackIcon
      }
    #endif
  }

  var body: some View {
    VStack(spacing: 16) {
      // App Icon
      appIcon

      // App Name
      Text(appName)
        .font(.title)
        .fontWeight(.semibold)

      // Version and Build
      Text("Version \(appVersion) (\(buildVersion))")
        .font(.body)
        .foregroundColor(.secondary)

      // Git SHA
      Text("Build: \(gitSha)")
        .font(.caption)
        .foregroundColor(.secondary)
        .textSelection(.enabled)

      Spacer().frame(height: 8)

      // Copyright
      Text(copyright)
        .font(.caption)
        .foregroundColor(.secondary)
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
