//
//  SystemExtensionStatusTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

#if os(macOS)
  import Testing

  @testable import FirezoneKit

  @Suite("SystemExtensionStatus.fromInstalledExtensions")
  struct SystemExtensionStatusTests {
    @Test("returns .needsInstall when no extensions are present")
    func noExtensions() {
      let status = SystemExtensionStatus.fromInstalledExtensions(
        [],
        appBundleVersion: "42",
        appBundleShortVersion: "1.0.0"
      )
      #expect(status == .needsInstall)
    }

    @Test("returns .installed when version matches exactly")
    func exactMatch() {
      let status = SystemExtensionStatus.fromInstalledExtensions(
        [(bundleVersion: "42", bundleShortVersion: "1.0.0")],
        appBundleVersion: "42",
        appBundleShortVersion: "1.0.0"
      )
      #expect(status == .installed)
    }

    @Test("returns .needsReplacement when short version differs (upgrade)")
    func upgradeNeeded() {
      let status = SystemExtensionStatus.fromInstalledExtensions(
        [(bundleVersion: "41", bundleShortVersion: "0.9.0")],
        appBundleVersion: "42",
        appBundleShortVersion: "1.0.0"
      )
      #expect(status == .needsReplacement)
    }

    @Test("returns .needsReplacement when build number differs but short version matches")
    func buildNumberMismatch() {
      let status = SystemExtensionStatus.fromInstalledExtensions(
        [(bundleVersion: "41", bundleShortVersion: "1.0.0")],
        appBundleVersion: "42",
        appBundleShortVersion: "1.0.0"
      )
      #expect(status == .needsReplacement)
    }

    @Test("returns .needsReplacement on downgrade")
    func downgrade() {
      let status = SystemExtensionStatus.fromInstalledExtensions(
        [(bundleVersion: "99", bundleShortVersion: "2.0.0")],
        appBundleVersion: "42",
        appBundleShortVersion: "1.0.0"
      )
      #expect(status == .needsReplacement)
    }

    @Test("returns .installed if any extension matches among multiple")
    func multipleExtensionsOneMatches() {
      let status = SystemExtensionStatus.fromInstalledExtensions(
        [
          (bundleVersion: "40", bundleShortVersion: "0.8.0"),
          (bundleVersion: "42", bundleShortVersion: "1.0.0"),
        ],
        appBundleVersion: "42",
        appBundleShortVersion: "1.0.0"
      )
      #expect(status == .installed)
    }

    @Test("returns .needsReplacement when multiple extensions exist but none match")
    func multipleExtensionsNoneMatch() {
      let status = SystemExtensionStatus.fromInstalledExtensions(
        [
          (bundleVersion: "40", bundleShortVersion: "0.8.0"),
          (bundleVersion: "41", bundleShortVersion: "0.9.0"),
        ],
        appBundleVersion: "42",
        appBundleShortVersion: "1.0.0"
      )
      #expect(status == .needsReplacement)
    }
  }
#endif
