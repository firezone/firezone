//
//  ObjCExceptionTests.swift
//  (c) 2024 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import FirezoneKitObjC
import Foundation
import Testing

@testable import FirezoneKit

@Suite("ObjC Exception Catching Tests")
struct ObjCExceptionTests {

  @Test("catchingObjCException catches raised NSException")
  func catchesRaisedException() async {
    var caughtException: ObjCException?

    do {
      try catchingObjCException {
        // Directly raise an NSException - this is what Foundation does internally
        NSException(
          name: NSExceptionName("TestException"),
          reason: "Test exception reason",
          userInfo: nil
        ).raise()
      }
      #expect(Bool(false), "Should have thrown an exception")
    } catch let error as ObjCException {
      caughtException = error
    } catch {
      Issue.record("Should have caught ObjCException, got \(error)")
    }

    #expect(caughtException != nil, "Exception should have been caught")
    #expect(caughtException?.name == "TestException")
    #expect(caughtException?.reason == "Test exception reason")
  }
}
