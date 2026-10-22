/// UniFFI renders `ConnlibError` as an opaque class, so what connlib put in it is
/// only reachable through `message()`. The generated `errorDescription` reflects on
/// the class instead, which leaves the log line, the string interpolation and the
/// crash report all naming the type and nothing else.
extension ConnlibError: CustomStringConvertible, CustomDebugStringConvertible {
  public var description: String { message() }

  /// The generated `errorDescription` is `String(reflecting: self)`, so this is
  /// what ends up in `localizedDescription`.
  public var debugDescription: String { message() }
}
