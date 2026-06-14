# AI agent rules for Firezone Rust code

## Code style

- Do not generate excessive comments
- Document the code, not the change that introduced it. A comment should read the
  same a year later to someone who never saw the diff: describe what the code does
  and why it must work that way, not how it differs from what it replaced. Avoid
  change-relative wording like "instead of", "now", "no longer", or "previously".
  The reason a change is made belongs in the commit message — and, at a high level,
  in the PR description, which becomes the squash-merge commit message — not in a
  code comment.
- Prefer a functional style (i.e. Iterators) over imperative code
- Prefer turbofish over explicit type-hints
- Prefer early-returns in functions to keep the indentation of the happy-path minimal, i.e. use `let-else` instead of `if let`
- When writing tests, focus on the public API of the module
- Follow the arrange - act - assert pattern
- Order functions within a module from high to low priority: Public API first, then sorted roughly in order of how they are called.
  Scrolling further down should be roughly equivalent to drilling down into details as to how the module works.

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
- Prefer logging values instead of formatting them into the message. For example, use:

  ```rust
  tracing::info!(?duration_since_intent, "Established new connection");
  ```

  instead of

  ```rust
  tracing::info!("Established new connection in {duration_since_intent:?}");
  ```
