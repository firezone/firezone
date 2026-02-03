//
//  ObjCException.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0

import FirezoneKitObjC
import Foundation

/// Swift error type for Objective-C exceptions
public struct ObjCException: Error {
  public let name: String
  public let reason: String?

  public var localizedDescription: String {
    if let reason = reason {
      return "\(name): \(reason)"
    }
    return name
  }
}

/// Executes a closure and converts any Objective-C exceptions to Swift errors.
public func catchingObjCException<T>(_ body: () throws -> T) throws -> T {
  var result: T?
  var caughtError: Error?

  if let exception = tryObjC({
    do {
      result = try body()
    } catch {
      caughtError = error
    }
  }) {
    throw ObjCException(
      name: exception.name.rawValue,
      reason: exception.reason
    )
  }

  if let error = caughtError {
    throw error
  }

  // Force unwrapping is okay here. We throw an error in all other code-paths.
  // swiftlint:disable:next force_unwrapping.
  return result!
}
