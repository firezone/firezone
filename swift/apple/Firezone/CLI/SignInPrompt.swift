//
//  SignInPrompt.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import ArgumentParser
import Darwin
import FirezoneKit
import Foundation

/// Walks the user through browser sign-in and reads the token back from the terminal.
enum SignInPrompt {
  private static let tokenBufferSize = 4096

  static func requestToken(authBaseURL: String, accountSlug: String) async throws -> Token {
    let url = try signInURL(authBaseURL: authBaseURL, accountSlug: accountSlug)

    print(
      """

      ==========================================================================
      Firezone Headless Client - Browser Authentication
      ==========================================================================

      To sign in to Firezone, please follow these steps:

      1. Open the following URL in your web browser:

         \(url)

      2. Complete the sign-in process in your browser
      3. Copy the token displayed in the browser
      4. Return to this terminal and paste the token below

      ==========================================================================

      """)
    let entered =
      await readHiddenLine(prompt: "Enter the token from your browser: ")?
      .trimmingCharacters(in: .whitespacesAndNewlines)

    guard let entered, !entered.isEmpty else {
      throw CLIError("No token provided")
    }

    guard let token = Token(entered) else {
      throw CLIError("Invalid token")
    }

    return token
  }

  private static func signInURL(authBaseURL: String, accountSlug: String) throws -> URL {
    guard var components = URLComponents(string: authBaseURL) else {
      throw ValidationError("Invalid auth base URL: \(authBaseURL)")
    }

    if !accountSlug.isEmpty {
      components.path += components.path.hasSuffix("/") ? accountSlug : "/\(accountSlug)"
    }

    components.queryItems =
      (components.queryItems ?? []) + [URLQueryItem(name: "as", value: "headless-client")]

    guard let url = components.url else {
      throw ValidationError("Failed to construct auth URL")
    }

    return url
  }

  /// `readpassphrase` blocks, so it runs off the cooperative pool. Keeping the main actor
  /// free is what lets SIGINT and SIGTERM still be handled while we wait for the user.
  private static func readHiddenLine(prompt: String) async -> String? {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(returning: readHiddenLineBlocking(prompt: prompt))
      }
    }
  }

  /// Reads a line without echoing it.
  ///
  /// `readpassphrase` talks to `/dev/tty` instead of standard input, and puts the
  /// terminal back itself, including when a signal interrupts the read. Turning echo off
  /// on standard input by hand does not hold up here: the call is refused, and the token
  /// is typed in the clear.
  private static func readHiddenLineBlocking(prompt: String) -> String? {
    var buffer = [CChar](repeating: 0, count: tokenBufferSize)

    // It's a credential, so don't leave it lying around in freed memory.
    defer {
      buffer.withUnsafeMutableBytes { bytes in
        _ = memset_s(bytes.baseAddress, bytes.count, 0, bytes.count)
      }
    }

    let result = buffer.withUnsafeMutableBufferPointer { pointer in
      readpassphrase(
        prompt,
        pointer.baseAddress,
        pointer.count,
        RPP_ECHO_OFF | RPP_REQUIRE_TTY)
    }

    guard result != nil else { return nil }

    let entered = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }

    return String(bytes: entered, encoding: .utf8)
  }
}
