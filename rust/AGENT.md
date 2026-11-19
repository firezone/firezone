# AI agent rules for Firezone Rust code

Follow the [Rust coding guidelines](CODING_GUIDELINES.md).

## Use of log levels

- Sensitive information such as domain names or customer IP addresses MUST NOT be logged above `DEBUG`.
  When in doubt, err on the side of caution and use `DEBUG`.
- Anything that is triggered by individual network packets MUST be on `TRACE` level.
- In general, use these rules of thumb for choosing a log level:
  - `TRACE`: Use for anything that "follows" along with the code, i.e. is executed unconditionally, like every incoming packet.
  - `DEBUG`: Usually coupled with a condition or minor state change in the system, like an early exit from a function or a deviation from the happy path. Think, "I would want to know that this triggered to understand what the system does."
  - `INFO`: Use for significant, often user-impacting, state changes in the system, i.e. a connection has been established or closed.
  - `WARN`: Something (very) unusual has happened but so far, everything still works. Normal operation MAY trigger occasional `WARN` statements without them being an actual concern. A sysadmin or DevOps will likely set alerts on an increased number of `WARN` logs. If you log on `WARN`, consider whether or not it is important enough to wake an ops person at 3am.
  - `ERROR`: Something really bad happened and things are completely broken. We have to halt execution.
- Prefer `tracing::Span`s to provide context to a log statement over including fields in individual events, especially in highly-concurrent code where log messages may be interleaved. Try to avoid (debug)-printing entire structs in spans as they will only clutter the log, prefer identifiers such as connection IDs or resource IDs.
- `WARN` and `ERROR` logs create Sentry issues.
  A failure that is handled, retried or has a fallback is logged on `DEBUG`.
- Log on `DEBUG` (`TRACE` if it is triggered per packet) when a branch skips, drops or ignores something, so the behaviour of the system can be understood from its logs.
- A log message says what happened, nothing else.
  Don't repeat what a span, the module path or another log already says, and don't describe what happens next.
- Use the same message for the same event across code paths (e.g. Client and Gateway) and keep messages for different events unique so they can be found with `grep`.
- Embed an `anyhow::Error` in the message using the alternate format, which prints the entire chain of causes: `tracing::debug!("Failed to read config: {e:#}")`.
- Log a `Duration` with its `Debug` representation (`?elapsed`) and log points in time as a duration relative to now.
- Prefer logging values instead of formatting them into the message. For example, use:

  ```rust
  tracing::info!(?duration_since_intent, "Established new connection");
  ```

  instead of

  ```rust
  tracing::info!("Established new connection in {duration_since_intent:?}");
  ```

## Before pushing

- Run the quick checks for the crates you changed: `cargo fmt`, `cargo clippy --all-targets --all-features -p <crate>` and `cargo test -p <crate>`.
  Leave release builds and full-workspace rebuilds to CI.
