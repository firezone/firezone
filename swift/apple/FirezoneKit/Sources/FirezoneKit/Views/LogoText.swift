//
//  LogoText.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import SwiftUI

/// The flame-and-wordmark logo.
///
/// The image comes from the package's asset catalogue, which carries a light and a
/// dark rendition, so the color scheme needs no handling here. Only Xcode compiles
/// catalogues, though: under `swift test` the lookup resolves nothing, so renderers
/// without a compiled catalogue inject a replacement through `\.logoTextImage`.
struct LogoText: View {
  @Environment(\.logoTextImage) private var override

  var body: some View {
    (override ?? Image("LogoText", bundle: Bundle.module))
      .resizable()
      .scaledToFit()
  }
}

extension EnvironmentValues {
  /// A replacement for the wordmark, for renderers without a compiled catalogue.
  var logoTextImage: Image? {
    get { self[LogoTextImageKey.self] }
    set { self[LogoTextImageKey.self] = newValue }
  }
}

private struct LogoTextImageKey: EnvironmentKey {
  static var defaultValue: Image? { nil }
}
