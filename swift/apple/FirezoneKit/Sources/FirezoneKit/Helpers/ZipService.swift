// Inspired from https://gist.github.com/dreymonde/793a8a7c2ed5443b1594f528bb7c88a7

import Foundation

// MARK: - Extensions

extension URL {
  var isDirectory: Bool {
    (try? resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
  }
}

// MARK: - Errors

enum CreateZipError: Swift.Error {
  case urlNotADirectory(URL)
  case failedToEnumerateSource(URL)
  case failedToCreateZIP(Swift.Error)
  case failedToMoveZIP(Swift.Error)
}

// MARK: - ZipService

public final class ZipService {

  // NSFileCoordinator's `.forUploading` zip synthesis goes through a system
  // XPC service that occasionally fails transiently (NSPOSIXErrorDomain code
  // 0, "Undefined error: 0") under load with no indication anything is
  // actually wrong with the source directory. Retry before giving up.
  private static let maxAttempts = 3
  private static let retryDelay: TimeInterval = 0.2

  public static func createZip(
    source directoryURL: URL,
    to zipFinalURL: URL,
  ) throws {
    // see URL extension above
    guard directoryURL.isDirectory else {
      throw CreateZipError.urlNotADirectory(directoryURL)
    }

    for _ in 1..<maxAttempts {
      do {
        try stageAndZip(source: directoryURL, to: zipFinalURL)
        return
      } catch {
        Thread.sleep(forTimeInterval: retryDelay)
      }
    }

    try stageAndZip(source: directoryURL, to: zipFinalURL)
  }

  // Stage a copy of the directory and zip that instead: the source may contain
  // symlinks (the Rust file appender maintains `*.latest` links), which Apple's
  // zip-for-upload implementation chokes on when they dangle, and live log files
  // can be rotated or deleted mid-archive.
  private static func stageAndZip(source directoryURL: URL, to zipFinalURL: URL) throws {
    let fileManager = FileManager.default
    let stagingRootURL = fileManager
      .temporaryDirectory
      .appendingPathComponent("zip-staging-\(UUID().uuidString)")
    let stagingURL = stagingRootURL.appendingPathComponent(directoryURL.lastPathComponent)
    defer { try? fileManager.removeItem(at: stagingRootURL) }

    try copyRegularFiles(from: directoryURL, to: stagingURL)

    var fileManagerError: Swift.Error?
    var coordinatorError: NSError?

    NSFileCoordinator().coordinate(
      readingItemAt: stagingURL,
      options: .forUploading,
      error: &coordinatorError
    ) { zipAccessURL in
      do {
        try fileManager.moveItem(at: zipAccessURL, to: zipFinalURL)
      } catch {
        fileManagerError = error
      }
    }

    if let error = coordinatorError {
      throw CreateZipError.failedToCreateZIP(error)
    }

    if let error = fileManagerError {
      throw CreateZipError.failedToMoveZIP(error)
    }
  }

  // Recursively copies directories and regular files, skipping symlinks and
  // tolerating files that vanish while we're copying.
  private static func copyRegularFiles(from sourceURL: URL, to destinationURL: URL) throws {
    let fileManager = FileManager.default
    try fileManager.createDirectory(at: destinationURL, withIntermediateDirectories: true)

    let resourceKeys: Set<URLResourceKey> = [
      .isSymbolicLinkKey,
      .isDirectoryKey,
      .isRegularFileKey,
    ]
    guard
      let enumerator = fileManager.enumerator(
        at: sourceURL,
        includingPropertiesForKeys: Array(resourceKeys)
      )
    else {
      throw CreateZipError.failedToEnumerateSource(sourceURL)
    }

    let sourcePath = sourceURL.standardizedFileURL.path
    for case let itemURL as URL in enumerator {
      guard let resourceValues = try? itemURL.resourceValues(forKeys: resourceKeys),
        resourceValues.isSymbolicLink != true
      else {
        continue
      }

      let itemPath = itemURL.standardizedFileURL.path
      guard itemPath.hasPrefix(sourcePath + "/") else { continue }
      let relativePath = String(itemPath.dropFirst(sourcePath.count + 1))
      let targetURL = destinationURL.appendingPathComponent(relativePath)

      do {
        if resourceValues.isDirectory == true {
          try fileManager.createDirectory(at: targetURL, withIntermediateDirectories: true)
        } else if resourceValues.isRegularFile == true {
          try fileManager.copyItem(at: itemURL, to: targetURL)
        }
      } catch {
        if !isFileVanishedError(error) {
          throw error
        }
      }
    }
  }

  // A file disappearing between enumeration and copy is expected: log rotation
  // and the log size cleanup both delete files while an export may be running.
  private static func isFileVanishedError(_ error: Swift.Error) -> Bool {
    let nsError = error as NSError

    if nsError.domain == NSCocoaErrorDomain,
      nsError.code == NSFileReadNoSuchFileError || nsError.code == NSFileNoSuchFileError
    {
      return true
    }

    return nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOENT)
  }
}
