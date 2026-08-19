//
//  DeviceTrustSmoke.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import FirezoneKit
import Foundation

/// Prototype smoke test for the devicetrust UniFFI bindings.
///
/// Calling `parseClientCertificate(der:)` proves that the app target compiles the
/// generated bindings and links the `uniffi_devicetrust_*` symbols in `libconnlib.a`.
/// Remove once a real feature consumes the bindings.
enum DeviceTrustSmoke {
  static func run() {
    let info = parseClientCertificate(der: Data())

    Log.info("devicetrust parses empty DER as: \(String(describing: info))")
  }
}
