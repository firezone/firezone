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
  @MainActor
  public static func getDeviceName() -> String {
    // Returns a generic device name on iOS 16 and higher
    // See https://github.com/firezone/firezone/issues/3034
    #if os(iOS)
      return UIDevice.current.name
    #else
      return ProcessInfo.processInfo.hostName
    #endif
  }

  #if os(iOS)
    @MainActor
    public static func getIdentifierForVendor() -> String? {
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
