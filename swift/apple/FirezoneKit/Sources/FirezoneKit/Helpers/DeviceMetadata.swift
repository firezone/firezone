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
  // If firezone-id hasn't ever been written, the app is considered
  // to be launched for the first time.
  public static func firstTime() -> Bool {
    let fileExists = FileManager.default.fileExists(
      atPath: SharedAccess.baseFolderURL.appendingPathComponent("firezone-id").path
    )

    return !fileExists
  }

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
    let os = ProcessInfo.processInfo.operatingSystemVersion

    return "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
  }

  // Returns the Firezone ID as cached by the application or generates and persists a new one
  // if that doesn't exist. The Firezone ID is a UUIDv4 that is used to dedup this device
  // for upsert and identification in the admin portal.
  public static func getOrCreateFirezoneId() -> String {
    return getDeviceUuid()!
  }

}

#if os(iOS)
import UIKit

func getDeviceUuid() -> String? {
  return UIDevice.current.identifierForVendor?.uuidString
}
#else
import IOKit

func getDeviceUuid() -> String? {
    let matchingDict = IOServiceMatching("IOPlatformExpertDevice")

    let platformExpert = IOServiceGetMatchingService(kIOMainPortDefault, matchingDict)
    defer { IOObjectRelease(platformExpert) }

    if let uuid = IORegistryEntryCreateCFProperty(platformExpert, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0)?.takeUnretainedValue() as? String {
        return uuid
    }

    return nil
}
#endif
