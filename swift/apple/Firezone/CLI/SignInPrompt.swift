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
      try await readHiddenLine(prompt: "Enter the token from your browser: ")?
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

  /// Reading blocks, so it runs off the cooperative pool. Keeping the main actor free
  /// is what lets SIGINT and SIGTERM still be handled while we wait for the user.
  private static func readHiddenLine(prompt: String) async throws -> String? {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(with: Result { try readHiddenLineBlocking(prompt: prompt) })
      }
    }
  }

  /// Reads a line with the terminal's echo turned off.
  ///
  /// This works on the terminal already attached to standard input rather than opening
  /// `/dev/tty`, which is what the sandbox actually objects to.
  private static func readHiddenLineBlocking(prompt: String) throws -> String? {
    // Piped in, so there's nothing to hide and nothing to ask.
    guard isatty(STDIN_FILENO) == 1 else {
      return readLine()
    }

    var original = termios()
    guard tcgetattr(STDIN_FILENO, &original) == 0 else {
      throw refusal(reason: "couldn't read the terminal's settings", code: errno)
    }

    var muted = original
    muted.c_lflag &= ~UInt(ECHO)

    // Before the prompt, so nothing typed early is echoed on its way in, and flushing
    // so a stray keystroke can't be taken for the token.
    guard tcsetattr(STDIN_FILENO, TCSAFLUSH, &muted) == 0 else {
      throw refusal(reason: "the terminal wouldn't turn echo off", code: errno)
    }

    defer {
      tcsetattr(STDIN_FILENO, TCSAFLUSH, &original)
      print()  // Newline the muted Return didn't echo
    }

    print(prompt, terminator: "")
    fflush(stdout)

    return readLine()
  }

  /// Asking for a token the terminal is going to print is the wrong trade, so say how to
  /// pass one without a terminal, and carry enough detail to explain the refusal.
  private static func refusal(reason: String, code: Int32) -> CLIError {
    CLIError(
      """
      Refusing to ask for a token that would be typed in the clear: \(reason) \
      (errno \(code): \(String(cString: strerror(code)))). \
      Foreground process group \(tcgetpgrp(STDIN_FILENO)), ours \(getpgrp()), \
      session \(getsid(0)).

      Pass it without a terminal instead, either of:
        FIREZONE_TOKEN="$(cat token)" firezone-cli
        firezone-cli < token
      """)
  }
}
