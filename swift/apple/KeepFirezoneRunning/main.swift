import AppKit
import Foundation

private enum Constants {
  static let appGroupIdentifierInfoKey = "FirezoneAppGroupIdentifier"
  static let mainAppBundleIdentifierInfoKey = "FirezoneMainAppBundleIdentifier"
  static let applicationSupportFolderName = "Application Support"
  static let keepAppRunningSentinelFileName = ".running"
  static let mainAppPathEnvironmentVariable = "KEEP_FIREZONE_RUNNING_MAIN_APP_PATH"
  static let relaunchInterval: TimeInterval = 5
}

private struct MainApp {
  let url: URL
  let bundleIdentifier: String
}

final class KeepFirezoneRunningAppDelegate: NSObject, NSApplicationDelegate {
  private var didLogRunningSentinelResolutionFailure = false
  private var timer: Timer?

  func applicationDidFinishLaunching(_ notification: Notification) {
    NSLog(
      "[KeepFirezoneRunning] launched helper bundle=%@",
      Bundle.main.bundleURL.path
    )
    launchMainAppIfNeeded(trigger: "launch")

    timer = Timer.scheduledTimer(
      timeInterval: Constants.relaunchInterval,
      target: self,
      selector: #selector(handleTimer),
      userInfo: nil,
      repeats: true
    )
  }

  func applicationWillTerminate(_ notification: Notification) {
    timer?.invalidate()
  }

  @objc private func handleTimer() {
    launchMainAppIfNeeded(trigger: "timer")
  }

  private func launchMainAppIfNeeded(trigger: String) {
    guard shouldRelaunchMainApp else {
      return
    }

    guard let mainApp = resolveMainApp(trigger: trigger) else {
      return
    }

    let runningApplications = NSRunningApplication.runningApplications(
      withBundleIdentifier: mainApp.bundleIdentifier
    )

    guard runningApplications.isEmpty else {
      return
    }

    launch(mainApp, trigger: trigger)
  }

  private var shouldRelaunchMainApp: Bool {
    guard let runningSentinelURL else {
      if !didLogRunningSentinelResolutionFailure {
        didLogRunningSentinelResolutionFailure = true
        NSLog("[KeepFirezoneRunning] failed to resolve running sentinel location")
      }
      return false
    }

    return FileManager.default.fileExists(atPath: runningSentinelURL.path)
  }

  private func resolveMainApp(trigger: String) -> MainApp? {
    guard let mainAppURL = mainAppURL else {
      NSLog(
        "[KeepFirezoneRunning] %@: failed to resolve main app URL from helper bundle=%@",
        trigger,
        Bundle.main.bundleURL.path
      )
      return nil
    }

    guard let bundleIdentifier = mainAppBundleIdentifier else {
      NSLog(
        "[KeepFirezoneRunning] %@: failed to resolve main app bundle identifier for %@",
        trigger,
        mainAppURL.path
      )
      return nil
    }

    return MainApp(url: mainAppURL, bundleIdentifier: bundleIdentifier)
  }

  private func launch(_ mainApp: MainApp, trigger: String) {
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false

    NSWorkspace.shared.openApplication(at: mainApp.url, configuration: configuration) {
      runningApplication,
      error in
      if let error {
        NSLog(
          "[KeepFirezoneRunning] %@: failed to launch %@: %@",
          trigger,
          mainApp.url.path,
          error.localizedDescription
        )
        return
      }

      if let runningApplication {
        NSLog(
          "[KeepFirezoneRunning] %@: launched %@ pid=%d",
          trigger,
          mainApp.url.path,
          runningApplication.processIdentifier
        )
      } else {
        NSLog(
          "[KeepFirezoneRunning] %@: launch completed without app instance for %@",
          trigger,
          mainApp.url.path
        )
      }
    }
  }

  private var mainAppURL: URL? {
    if let mainAppPath = ProcessInfo.processInfo.environment[
      Constants.mainAppPathEnvironmentVariable],
      !mainAppPath.isEmpty
    {
      return URL(fileURLWithPath: mainAppPath)
    }

    let helperBundleURL = Bundle.main.bundleURL
    guard helperBundleURL.lastPathComponent == "KeepFirezoneRunning.app" else {
      return nil
    }

    return
      helperBundleURL
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
  }

  // The bundle identifier of the main app.
  //
  // This is loaded from our own plist and embedded at compile-time
  // so we can test this using a debug build from XCode as well.
  private var mainAppBundleIdentifier: String? {
    Bundle.main.object(forInfoDictionaryKey: Constants.mainAppBundleIdentifierInfoKey) as? String
  }

  private var runningSentinelURL: URL? {
    guard
      let appGroupIdentifier = Bundle.main.object(
        forInfoDictionaryKey: Constants.appGroupIdentifierInfoKey
      ) as? String,
      !appGroupIdentifier.isEmpty,
      let containerURL = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: appGroupIdentifier)
    else {
      return nil
    }

    let applicationSupportURL =
      containerURL
      .appendingPathComponent("Library")
      .appendingPathComponent(Constants.applicationSupportFolderName)

    guard ensureDirectoryExists(at: applicationSupportURL) else {
      return nil
    }

    return applicationSupportURL.appendingPathComponent(Constants.keepAppRunningSentinelFileName)
  }

  private func ensureDirectoryExists(at url: URL) -> Bool {
    let fileManager = FileManager.default

    do {
      var isDirectory: ObjCBool = false
      if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
        return isDirectory.boolValue
      }

      try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
      return true
    } catch {
      NSLog(
        "[KeepFirezoneRunning] failed to ensure directory exists at %@: %@",
        url.path,
        error.localizedDescription
      )
      return false
    }
  }
}

let application = NSApplication.shared
let delegate = KeepFirezoneRunningAppDelegate()
application.setActivationPolicy(.prohibited)
application.delegate = delegate
application.run()
