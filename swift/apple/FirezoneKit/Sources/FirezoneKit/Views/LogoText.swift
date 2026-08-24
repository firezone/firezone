//
//  LogoText.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import SwiftUI

#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

/// The flame-and-wordmark logo, in the variant for the current color scheme.
///
/// The variants live as loose PNGs in the package bundle rather than in an asset
/// catalogue: only Xcode compiles catalogues into a queryable `Assets.car`, while
/// `swift test` copies them verbatim, so a catalogue-backed image resolves nothing
/// when the screenshot tests render these screens. Without a catalogue there is no
/// appearance metadata either, hence the switch on the color scheme here.
///
/// The PNGs are loaded explicitly by URL: SwiftUI's named lookup does not search a
/// package bundle's loose files on macOS and silently draws nothing there. The 2x
/// rendition is preferred; the callers scale the image down, so it only adds
/// sharpness.
struct LogoText: View {
  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    image(variant: colorScheme == .dark ? "LogoTextDark" : "LogoText")
      .resizable()
      .scaledToFit()
  }

  private func image(variant name: String) -> Image {
    let url =
      Bundle.module.url(forResource: "\(name)@2x", withExtension: "png")
      ?? Bundle.module.url(forResource: name, withExtension: "png")

    #if os(macOS)
      guard let url, let image = NSImage(contentsOf: url) else {
        return Image(name, bundle: Bundle.module)
      }
      return Image(nsImage: image)
    #else
      guard let url, let image = UIImage(contentsOfFile: url.path) else {
        return Image(name, bundle: Bundle.module)
      }
      return Image(uiImage: image)
    #endif
  }
}
