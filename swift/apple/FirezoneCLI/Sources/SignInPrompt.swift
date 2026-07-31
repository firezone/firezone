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
  static func requestToken(authBaseURL: String, accountSlug: String) throws -> Token {
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

    // Restore default SIGINT handling so Ctrl+C works during the prompt
    signal(SIGINT, SIG_DFL)
    defer { signal(SIGINT, SIG_IGN) }

    guard let entered = readHiddenLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
      !entered.isEmpty
    else {
      throw ValidationError("No token provided")
    }

    guard let token = Token(entered) else {
      throw ValidationError("Invalid token")
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

  private static func readHiddenLine() -> String? {
    var original = termios()
    guard tcgetattr(STDIN_FILENO, &original) == 0 else {
      return readLine()  // Not a terminal, nothing to hide
    }

    var muted = original
    muted.c_lflag &= ~UInt(ECHO)
    tcsetattr(STDIN_FILENO, TCSANOW, &muted)
    defer {
      tcsetattr(STDIN_FILENO, TCSANOW, &original)
      print()  // Newline the hidden Return didn't echo
    }

    return readLine()
  }
}
