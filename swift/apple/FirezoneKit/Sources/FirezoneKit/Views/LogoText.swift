//
//  LogoText.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import SwiftUI

/// The flame-and-wordmark logo, in the variant for the current color scheme.
///
/// The variants live as loose PNGs in the package bundle rather than in an asset
/// catalogue: only Xcode compiles catalogues into a queryable `Assets.car`, while
/// `swift test` copies them verbatim, so a catalogue-backed image resolves nothing
/// when the screenshot tests render these screens. Without a catalogue there is no
/// appearance metadata either, hence the switch on the color scheme here.
struct LogoText: View {
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Image(colorScheme == .dark ? "LogoTextDark" : "LogoText", bundle: Bundle.module)
      .resizable()
      .scaledToFit()
  }
}
