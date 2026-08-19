//
//  X509IdentitySmoke.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import FirezoneKit
import Foundation

/// Prototype smoke test for the x509identity UniFFI bindings.
///
/// Calling `parseClientCertificate(der:)` proves that the app target compiles the
/// generated bindings and links the `uniffi_x509identity_*` symbols in `libconnlib.a`.
/// Remove once a real feature consumes the bindings.
enum X509IdentitySmoke {
  static func run() {
    let info = parseClientCertificate(der: Data())

    Log.info("x509identity parses empty DER as: \(String(describing: info))")
  }
}
