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
  case failedToCreateZIP(Swift.Error)
  case failedToMoveZIP(Swift.Error)
}

// MARK: - ZipService

public final class ZipService {

  public static func createZip(
    source directoryURL: URL,
    to zipFinalURL: URL,
  ) throws {
    // see URL extension below
    guard directoryURL.isDirectory else {
      throw CreateZipError.urlNotADirectory(directoryURL)
    }

    var fileManagerError: Swift.Error?
    var coordinatorError: NSError?

    NSFileCoordinator().coordinate(
      readingItemAt: directoryURL,
      options: .forUploading,
      error: &coordinatorError
    ) { zipAccessURL in
      do {
        try FileManager.default.moveItem(at: zipAccessURL, to: zipFinalURL)
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
}
