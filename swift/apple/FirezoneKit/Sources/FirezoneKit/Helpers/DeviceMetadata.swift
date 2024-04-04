//
//  DeviceMetadata.swift
//  Firezone
//
//  Created by Jamil Bou Kheir on 2/23/24.
//

import Foundation

#if os(iOS)
  import UIKit.UIDevice
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

  public static func getDeviceName() -> String? {
    // Returns a generic device name on iOS 16 and higher
    // See https://github.com/firezone/firezone/issues/3034
    #if os(iOS)
      return UIDevice.current.name
    #else
      // Fallback to connlib's gethostname()
      return nil
    #endif
  }

  public static func getOSVersion() -> String? {
    // Returns the OS version
    // See https://github.com/firezone/firezone/issues/3034
    return ProcessInfo.processInfo.operatingSystemVersionString
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
}
