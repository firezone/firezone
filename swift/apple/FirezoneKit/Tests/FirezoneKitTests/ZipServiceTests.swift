//
//  ZipServiceTests.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Foundation
import Testing

@testable import FirezoneKit

@Suite("ZipService tests")
struct ZipServiceTests {
  @Test("createZip succeeds when the source contains a dangling symlink")
  func zipWithDanglingSymlink() throws {
    let fileManager = FileManager.default
    let sourceURL = fileManager
      .temporaryDirectory
      .appendingPathComponent("logs-\(UUID().uuidString)")
    let nestedURL = sourceURL.appendingPathComponent("connlib")
    try fileManager.createDirectory(at: nestedURL, withIntermediateDirectories: true)
    defer { try? fileManager.removeItem(at: sourceURL) }

    try Data("log contents".utf8)
      .write(to: nestedURL.appendingPathComponent("connlib.2026-06-10.log"))
    try fileManager.createSymbolicLink(
      at: nestedURL.appendingPathComponent("connlib.latest"),
      withDestinationURL: nestedURL.appendingPathComponent("deleted.log")
    )

    let zipURL = fileManager
      .temporaryDirectory
      .appendingPathComponent("logs-\(UUID().uuidString).zip")
    defer { try? fileManager.removeItem(at: zipURL) }

    try ZipService.createZip(source: sourceURL, to: zipURL)

    let attributes = try fileManager.attributesOfItem(atPath: zipURL.path)
    #expect((attributes[.size] as? Int ?? 0) > 0)
  }

  @Test("createZip throws when the source is not a directory")
  func zipWithNonDirectorySource() throws {
    let fileManager = FileManager.default
    let sourceURL = fileManager
      .temporaryDirectory
      .appendingPathComponent("file-\(UUID().uuidString)")
    try Data("not a directory".utf8).write(to: sourceURL)
    defer { try? fileManager.removeItem(at: sourceURL) }

    let zipURL = fileManager
      .temporaryDirectory
      .appendingPathComponent("logs-\(UUID().uuidString).zip")

    #expect(throws: CreateZipError.self) {
      try ZipService.createZip(source: sourceURL, to: zipURL)
    }
  }
}
