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

  @Test("catchingObjCException rethrows Swift error")
  func rethrowsSwiftError() async {
    struct TestError: Error, Equatable {
      let message: String
    }

    var caughtError: TestError?

    do {
      try catchingObjCException {
        // Throw a Swift error - this should be rethrown as-is
        throw TestError(message: "Test Swift error")
      }
      #expect(Bool(false), "Should have thrown an error")
    } catch let error as TestError {
      caughtError = error
    } catch {
      Issue.record("Should have caught TestError, got \(error)")
    }

    #expect(caughtError != nil, "Swift error should have been rethrown")
    #expect(caughtError?.message == "Test Swift error")
  }
}
