//
//  TunnelStatus.swift
//  (c) 2026 Firezone, Inc.
//  LICENSE: Apache-2.0
//

/// What the extension knows about the session, stated on request.
///
/// A poll answers "nothing changed" when it has nothing new, and a caller holding no
/// earlier state cannot tell that from "nothing there". This is a plain statement
/// instead, so a one-shot process never has to infer a state from an absence.
public enum TunnelStatus: Codable, Equatable, Sendable {
  /// No token is stored, so nothing could connect.
  case signedOut
  /// A token is stored but no tunnel is running.
  case signedIn
  /// The tunnel is up and the portal has not yet said who this is.
  case connecting
  /// The portal has named the session. Either can be empty when it did not.
  case connected(accountSlug: String?, actorName: String?)
}
