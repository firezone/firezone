//
//  SignInPrompt.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import ArgumentParser
import FirezoneKit
import Foundation

/// Walks the user through browser sign-in and reads the token back from the terminal.
enum SignInPrompt {
  private static let terminalLock = NSLock()
  nonisolated(unsafe) private static var mutedTerminal: termios?

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
    print("Enter the token from your browser: ", terminator: "")
    fflush(stdout)

    let entered = await readHiddenLine()?.trimmingCharacters(in: .whitespacesAndNewlines)

    guard let entered, !entered.isEmpty else {
      throw CLIError("No token provided")
    }

    guard let token = Token(entered) else {
      throw CLIError("Invalid token")
    }

    return token
  }

  /// Re-enables terminal echo. Called on the way out in case we're shutting down while
  /// a prompt is still blocked on stdin, which would otherwise leave the terminal muted.
  static func restoreTerminal() {
    terminalLock.withLock {
      guard var original = mutedTerminal else { return }
      tcsetattr(STDIN_FILENO, TCSANOW, &original)
      mutedTerminal = nil
    }
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

  /// `readLine` blocks, so it runs off the cooperative pool. Keeping the main actor free
  /// is what lets SIGINT and SIGTERM still be handled while we wait for the user.
  private static func readHiddenLine() async -> String? {
    await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(returning: readHiddenLineBlocking())
      }
    }
  }

  private static func readHiddenLineBlocking() -> String? {
    var original = termios()
    guard tcgetattr(STDIN_FILENO, &original) == 0 else {
      return readLine()  // Not a terminal, so there's no echo to suppress
    }

    var muted = original
    muted.c_lflag &= ~UInt(ECHO)
    terminalLock.withLock { mutedTerminal = original }
    tcsetattr(STDIN_FILENO, TCSANOW, &muted)

    defer {
      restoreTerminal()
      print()  // Newline the muted Return didn't echo
    }

    return readLine()
  }
}
