//
//  DeviceMetadata.swift
//  Firezone
//
//  Created by Jamil Bou Kheir on 2/23/24.
//

import Foundation

#if os(iOS)
  import UIKit
#endif

public class DeviceMetadata {
  // nonisolated(unsafe) is safe here because:
  // 1. UIDevice.current properties are thread-safe for reads (per Apple documentation)
  // 2. Properties are immutable or internally synchronised
  // 3. Only reading, never mutating UIDevice state
  public static nonisolated(unsafe) func getDeviceName() -> String {
    // Returns a generic device name on iOS 16 and higher
    // See https://github.com/firezone/firezone/issues/3034
    #if os(iOS)
      return UIDevice.current.name
    #else
      // Use hostname
      return ProcessInfo.processInfo.hostName
    #endif
  }

  public static func getOSVersion() -> String {
    // Returns the OS version. Must be valid ASCII.
    // See https://github.com/firezone/firezone/issues/3034
    // See https://github.com/firezone/firezone/issues/5467
    let osVersion = ProcessInfo.processInfo.operatingSystemVersion

    return "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
  }

  #if os(iOS)
    public static nonisolated(unsafe) func getIdentifierForVendor() -> String? {
      return UIDevice.current.identifierForVendor?.uuidString
    }
  #endif
}

#if os(macOS)
  import IOKit

  public func getDeviceUuid() -> String? {
    return getDeviceInfo(key: kIOPlatformUUIDKey as CFString)
  }

  public func getDeviceSerial() -> String? {
    return getDeviceInfo(key: kIOPlatformSerialNumberKey as CFString)
  }

  private func getDeviceInfo(key: CFString) -> String? {
    let matchingDict = IOServiceMatching("IOPlatformExpertDevice")

    let platformExpert = IOServiceGetMatchingService(kIOMainPortDefault, matchingDict)
    defer { IOObjectRelease(platformExpert) }

    if let serial = IORegistryEntryCreateCFProperty(
      platformExpert,
      key,
      kCFAllocatorDefault,
      0
    )?.takeUnretainedValue() as? String {
      return serial
    }

    return nil
  }
#endif
