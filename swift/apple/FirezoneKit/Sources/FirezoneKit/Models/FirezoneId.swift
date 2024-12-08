//
//  FirezoneId.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//
//  Convenience wrapper for working with our firezone-id stored in the Keychain.

import Foundation

public struct FirezoneId {
  private static let query: [CFString: Any] = [
    kSecAttrLabel: "Firezone id",
    kSecAttrAccount: "2",
    kSecAttrService: AppInfoPlistConstants.appGroupId,
    kSecAttrDescription: "Firezone device id",
  ]

  private var uuid: UUID

  public init(_ uuid: UUID? = nil) {
    self.uuid = uuid ?? UUID()
  }

  // Upsert the firezone-id to the Keychain
  public func save() async throws {
    guard await Keychain.shared.search(query: FirezoneId.query) == nil
    else {
      let query = FirezoneId.query.merging([
        kSecClass: kSecClassGenericPassword
      ]) { (_, new) in new }
      return try await Keychain.shared.update(
        query: query,
        attributesToUpdate: [kSecValueData: uuid.toData()]
      )
    }

    let query = FirezoneId.query.merging([
      kSecClass: kSecClassGenericPassword,
      kSecValueData: uuid.toData()
    ]) { (_, new) in new }

    try await Keychain.shared.add(query: query)
  }

  // Attempt to load the firezone-id from the Keychain
  public static func load() async throws -> FirezoneId? {
    guard let idRef = await Keychain.shared.search(query: query)
    else { return nil }

    guard let data = await Keychain.shared.load(persistentRef: idRef)
    else { return nil }

    guard data.count == UUID.sizeInBytes
    else {
      fatalError("Firezone ID loaded from keychain must be exactly \(UUID.sizeInBytes) bytes")
    }

    let uuid = UUID(fromData: data)
    return FirezoneId(uuid)
  }

  // Prior to 1.4.0, our firezone-id was saved in a file. Starting with 1.4.0,
  // the macOS client uses a system extension, which makes sharing folders with
  // the app cumbersome, so we moved to using the keychain for this due to its
  // better ergonomics.
  //
  // Can be refactored to remove the file check once all clients >= 1.4.0
  public static func createIfMissing() async throws {
    guard try await load() == nil
    else { return } // New firezone-id already saved in Keychain

    let appGroupIdPre_1_4_0 = "47R2M6779T.group.dev.firezone.firezone"

    guard let containerURL = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: appGroupIdPre_1_4_0)
    else { fatalError("Couldn't find app group container") }

    let idFileURL = containerURL.appendingPathComponent("firezone-id")

    var uuid: UUID?

    if FileManager.default.fileExists(atPath: idFileURL.path),
       let uuidString = try? String(contentsOf: idFileURL)
    {

      // Read legacy file-based id if it exists
      uuid = UUID(uuidString: uuidString)
    } else {

      // Otherwise generate a new one
      uuid = UUID()
    }

    let firezoneId = FirezoneId(uuid)
    try await firezoneId.save()
  }
}

// Convenience extension to convert to/from Data for storing in Keychain
extension UUID {

  // For UUIDv4 this will be 16, but we want to be flexible in case the UUID API
  // is updated in the future to use a newer version with different byte size.
  public static let sizeInBytes = MemoryLayout.size(ofValue: UUID())

  init(fromData: Data) {
    self = fromData.withUnsafeBytes { rawBufferPointer in
      guard let baseAddress = rawBufferPointer.baseAddress
      else {
        fatalError("Buffer should point to a valid memory address")
      }

      return UUID(uuid: baseAddress.assumingMemoryBound(to: uuid_t.self).pointee)
    }
  }

  func toData() -> Data {
    let data = withUnsafePointer(to: self) { rawBufferPinter in
      Data(bytes: rawBufferPinter, count: UUID.sizeInBytes)
    }

    return data
  }
}
