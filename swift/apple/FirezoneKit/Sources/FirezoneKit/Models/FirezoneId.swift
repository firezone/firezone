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
    kSecAttrService: BundleHelper.appGroupId,
    kSecAttrDescription: "Firezone device id",
  ]

  public var uuid: UUID

  public init(_ uuid: UUID? = nil) {
    self.uuid = uuid ?? UUID()
  }

  // Upsert the firezone-id to the Keychain
  public func save() throws {
    guard Keychain.search(query: FirezoneId.query) == nil
    else {
      let query = FirezoneId.query.merging([
        kSecClass: kSecClassGenericPassword
      ]) { (_, new) in new }
      return try Keychain.update(
        query: query,
        attributesToUpdate: [kSecValueData: uuid.toData()]
      )
    }

    let query = FirezoneId.query.merging([
      kSecClass: kSecClassGenericPassword,
      kSecValueData: uuid.toData()
    ]) { (_, new) in new }

    try Keychain.add(query: query)
  }

  // Attempt to load the firezone-id from the Keychain
  public static func load() throws -> FirezoneId? {
    guard let idRef = Keychain.search(query: query)
    else { return nil }

    guard let data = Keychain.load(persistentRef: idRef)
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
  // better ergonomics. If the old firezone-id doesn't exist, this function
  // is a no-op.
  //
  // Can be refactored to remove the file check once all clients >= 1.4.0
  public static func migrate() throws {
    guard try load() == nil
    else { return } // New firezone-id already saved in Keychain

#if os(macOS)
    let appGroupIdPre_1_4_0 = "47R2M6779T.group.dev.firezone.firezone"
#elseif os(iOS)
    let appGroupIdPre_1_4_0 = "group.dev.firezone.firezone"
#endif

    guard let containerURL = FileManager.default.containerURL(
      forSecurityApplicationGroupIdentifier: appGroupIdPre_1_4_0)
    else { fatalError("Couldn't find app group container") }

    let idFileURL = containerURL.appendingPathComponent("firezone-id")

    // If the file isn't there or can't be read, bail
    guard FileManager.default.fileExists(atPath: idFileURL.path),
          let uuidString = try? String(contentsOf: idFileURL)
    else { return }

    let firezoneId = FirezoneId(UUID(uuidString: uuidString))
    try firezoneId.save()
  }

  public static func createIfMissing() throws -> FirezoneId {
    guard let id = try load()
    else {
      let id = FirezoneId(UUID())
      try id.save()

      return id
    }

    // New firezone-id already saved in Keychain
    return id
  }
}

// Convenience extension to convert to/from Data for storing in Keychain
extension UUID {
  // We need the size of a UUID to (1) know how big to make the Data buffer,
  // and (2) to make sure the UUID we read from the keychain is a valid length.
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
