import FirezoneKit
import Foundation

/// Commands sent from Adapter to PacketTunnelProvider.
///
/// All cases and associated values are Sendable, enabling compiler-verified
/// thread-safe communication without @unchecked Sendable.
enum ProviderCommand: Sendable {
  /// Cancel the tunnel with an optional error.
  case cancelWithError(SendableError?)

  /// Set the reasserting state (network transition indicator).
  case setReasserting(Bool)

  /// Get the current reasserting state. Response sent via the provided channel.
  case getReasserting(Sender<Bool>)

  /// Start the log cleanup task after successful tunnel startup.
  case startLogCleanupTask

  /// Apply network settings. Error message (nil on success) sent via the provided channel.
  case applyNetworkSettings(NetworkSettings.Payload, Sender<String?>)
}

/// Sendable wrapper for Error since Error itself is not Sendable.
///
/// Captures the essential error information needed for tunnel cancellation.
struct SendableError: Sendable {
  let message: String
  let isAuthenticationError: Bool

  init(_ message: String, isAuthenticationError: Bool = false) {
    self.message = message
    self.isAuthenticationError = isAuthenticationError
  }
}
