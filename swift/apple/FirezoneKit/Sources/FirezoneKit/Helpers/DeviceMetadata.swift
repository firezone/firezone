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
  public static func getDeviceName() -> String {
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
    public static func deviceInfo() -> DeviceInfo {
      return DeviceInfo(
        deviceUuid: nil,
        deviceSerial: nil,
        identifierForVendor: UIDevice.current.identifierForVendor!.uuidString
      )
    }
  #else
    public static func deviceInfo() -> DeviceInfo {
      return DeviceInfo(
        deviceUuid: getDeviceUuid(),
        deviceSerial: getDeviceSerial(),
        identifierForVendor: nil
      )
    }
  #endif
}

public struct DeviceInfo {
  public let deviceUuid: String?
  public let deviceSerial: String?
  public let identifierForVendor: String?
}

#if os(macOS)
  import IOKit

  func getDeviceUuid() -> String? {
    return getDeviceInfo(key: kIOPlatformUUIDKey as CFString)
  }

  func getDeviceSerial() -> String? {
    return getDeviceInfo(key: kIOPlatformSerialNumberKey as CFString)
  }

  func getDeviceInfo(key: CFString) -> String? {
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
