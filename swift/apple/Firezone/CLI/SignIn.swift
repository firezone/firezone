//
//  SignIn.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

import Darwin
import FirezoneKit
import Foundation

/// Where a token comes from, and what to tell someone who hasn't got one.
///
/// Nothing is ever typed at a prompt. The app is sandboxed, and a sandboxed process
/// isn't allowed to turn terminal echo off, so asking would leave a credential sitting
/// in the scrollback. Piping one in avoids the terminal altogether.
enum SignIn {
  /// The token piped into the process, if there is one.
  ///
  /// Nothing is read from a terminal: with no pipe there is nothing waiting, and asking
  /// would just block.
  static func pipedToken() -> Token? {
    guard isatty(STDIN_FILENO) == 0 else { return nil }

    guard let piped = readLine()?.trimmingCharacters(in: .whitespacesAndNewlines),
      !piped.isEmpty
    else { return nil }

    return Token(piped)
  }

  /// What to do about not having a token, written out so it can be followed as-is.
  static func instructions(authBaseURL: String, accountSlug: String) -> String {
    let url = signInURL(authBaseURL: authBaseURL, accountSlug: accountSlug)
    let command = CommandLine.arguments.first ?? "firezone-cli"

    return """
      No token to sign in with.

        1. Open this in a browser and sign in:

           \(url)

        2. Copy the token it gives you.

        3. Run this, which hands the token over without it appearing on screen:

           pbpaste | \(command)

      A token can come from FIREZONE_TOKEN or from a file instead:

           \(command) < token

      Whichever way it arrives, the Keychain keeps it and later runs need none of this.
      """
  }

  private static func signInURL(authBaseURL: String, accountSlug: String) -> String {
    guard var components = URLComponents(string: authBaseURL) else {
      return authBaseURL
    }

    if !accountSlug.isEmpty {
      components.path += components.path.hasSuffix("/") ? accountSlug : "/\(accountSlug)"
    }

    components.queryItems =
      (components.queryItems ?? []) + [URLQueryItem(name: "as", value: "headless-client")]

    return components.url?.absoluteString ?? authBaseURL
  }
}
