//
//  PrimaryMacAddress.swift
//  (c) 2023 Firezone, Inc.
//  LICENSE: Apache-2.0
//
// Contains convenience methods for getting a device ID for macOS.

// Believe it or not, this is Apple's recommended way of doing things for macOS
// See https://developer.apple.com/documentation/appstorereceipts/validating_receipts_on_the_device#//apple_ref/doc/uid/TP40010573-CH1-SW14

import IOKit
import Foundation
import OSLog

public class PrimaryMacAddress {
  // Returns an object with a +1 retain count; the caller needs to release.
  private static func io_service(named name: String, wantBuiltIn: Bool) -> io_service_t? {
    let default_port = kIOMainPortDefault
    var iterator = io_iterator_t()
    defer {
      if iterator != IO_OBJECT_NULL {
        IOObjectRelease(iterator)
      }
    }

    guard let matchingDict = IOBSDNameMatching(default_port, 0, name),
          IOServiceGetMatchingServices(default_port,
                                       matchingDict as CFDictionary,
                                       &iterator) == KERN_SUCCESS,
          iterator != IO_OBJECT_NULL
    else {
      return nil
    }

    var candidate = IOIteratorNext(iterator)
    while candidate != IO_OBJECT_NULL {
      if let cftype = IORegistryEntryCreateCFProperty(candidate,
                                                      "IOBuiltin" as CFString,
                                                      kCFAllocatorDefault,
                                                      0) {
        let isBuiltIn = cftype.takeRetainedValue() as! CFBoolean
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
    guard let service = io_service(named: "en0", wantBuiltIn: true)
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
      return (cftype as! CFData)
    }


    return nil
  }
}
