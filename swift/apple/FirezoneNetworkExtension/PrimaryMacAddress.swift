//
//  PrimaryMacAddress.swift
//  (c) 2023 Firezone, Inc.
//  LICENSE: Apache-2.0
//
// Contains convenience methods for getting a device ID for macOS.

// Believe it or not, this is Apple's recommended way of doing things for macOS
// swiftlint:disable line_length
// See https://developer.apple.com/documentation/appstorereceipts/validating_receipts_on_the_device#//apple_ref/doc/uid/TP40010573-CH1-SW14
// swiftlint:enable line_length

import Foundation
import IOKit
import OSLog

public class PrimaryMacAddress {
  // Returns an object with a +1 retain count; the caller needs to release.
  private static func io_service(named name: String, wantBuiltIn: Bool) -> io_service_t? {
    let defaultPort = kIOMainPortDefault
    var iterator = io_iterator_t()
    defer {
      if iterator != IO_OBJECT_NULL {
        IOObjectRelease(iterator)
      }
    }

    guard let matchingDict = IOBSDNameMatching(defaultPort, 0, name),
      IOServiceGetMatchingServices(
        defaultPort,
        matchingDict as CFDictionary,
        &iterator) == KERN_SUCCESS,
      iterator != IO_OBJECT_NULL
    else {
      return nil
    }

    var candidate = IOIteratorNext(iterator)
    while candidate != IO_OBJECT_NULL {
      if let cftype = IORegistryEntryCreateCFProperty(
        candidate,
        "IOBuiltin" as CFString,
        kCFAllocatorDefault,
        0) {
        // swiftlint:disable force_cast
        let isBuiltIn = cftype.takeRetainedValue() as! CFBoolean
        // swiftlint:enable force_cast
        if wantBuiltIn == CFBooleanGetValue(isBuiltIn) {
          return candidate
        }
      }

      IOObjectRelease(candidate)
      candidate = IOIteratorNext(iterator)
    }

    return nil
  }

  public static func copy_mac_address() -> CFData? {
    // Prefer built-in network interfaces.
    // For example, an external Ethernet adaptor can displace
    // the built-in Wi-Fi as en0.
    guard
      let service = io_service(named: "en0", wantBuiltIn: true)
        ?? io_service(named: "en1", wantBuiltIn: true)
        ?? io_service(named: "en0", wantBuiltIn: false)
    else { return nil }
    defer { IOObjectRelease(service) }

    if let cftype = IORegistryEntrySearchCFProperty(
      service,
      kIOServicePlane,
      "IOMACAddress" as CFString,
      kCFAllocatorDefault,
      IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)) {
      // swiftlint:disable force_cast
      return (cftype as! CFData)
      // swiftlint:enable force_cast
    }

    return nil
  }
}
