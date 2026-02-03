//
//  ObjCException.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//
//  Utilities for catching Objective-C exceptions and converting them to Swift errors.
//
//  USAGE:
//
//  1. Convert NSException to Swift error (forces try/catch):
//
//     do {
//       try catchingObjCException {
//         fileHandle.write(contentsOf: data)  // Might throw NSException
//       }
//     } catch let error as ObjCException {
//       print("Exception: \(error.localizedDescription)")
//     }
//
//  2. With return values:
//
//     let result = try catchingObjCException {
//       return someObjCMethod()  // Returns value, might throw NSException
//     }
//
//  3. Simple catch without converting to error (doesn't force try/catch):
//
//     if let exception = tryObjC {
//       fileHandle.write(contentsOf: data)
//     } {
//       print("Caught: \(exception)")
//     }
//

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
/// Forces compile-time error handling with Swift's `try` keyword.
///
/// Usage:
/// ```
/// // Without return value:
/// try catchingObjCException {
///     fileHandle.write(contentsOf: data)
/// }
///
/// // With return value:
/// let result = try catchingObjCException {
///     return someObjCMethod()
/// }
/// ```
///
/// - Parameter body: The closure to execute that may throw NSException
/// - Returns: The value returned by the closure (or Void if closure returns nothing)
/// - Throws: ObjCException if an NSException is caught
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

  // Re-throw any Swift errors that occurred
  if let error = caughtError {
    throw error
  }

  // Force unwrapping is okay here. We throw an error in all other code-paths.
  // swiftlint:disable:next force_unwrapping.
  return result!
}
