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
      let fileURL = SharedAccess.baseFolderURL.appendingPathComponent("firezone-id")

      do {
        return try String(contentsOf: fileURL, encoding: .utf8)
      } catch {
        // Handle the error if the file doesn't exist or isn't readable
        // Recreate the file, save a new UUIDv4, and return it
        let newUUIDString = UUID().uuidString

        do {
          try newUUIDString.write(to: fileURL, atomically: true, encoding: .utf8)
        } catch {
          Log.app.error(
            "\(#function): Could not save firezone-id file \(fileURL.path)! Error: \(error)"
          )
        }

        return newUUIDString
      }
    }

#if os(iOS)
  public static func deviceInfo() -> DeviceInfo {
    return DeviceInfo(identifierForVendor: UIDevice.current.identifierForVendor!.uuidString)
  }
#else
  public static func deviceInfo() -> DeviceInfo {
    return DeviceInfo(deviceUuid: getDeviceUuid()!, deviceSerial: getDeviceSerial()!)
  }
#endif
}

#if os(iOS)
public struct DeviceInfo: Encodable {
  let identifierForVendor: String
}
#endif

#if os(macOS)
import IOKit

public struct DeviceInfo: Encodable {
  let deviceUuid: String
  let deviceSerial: String
}

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

  if let serial = IORegistryEntryCreateCFProperty(platformExpert, key, kCFAllocatorDefault, 0)?.takeUnretainedValue() as? String {
      return serial
  }

  return nil
}
#endif
