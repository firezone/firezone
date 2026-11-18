# Rust coding guidelines

Rules for all Rust code in this repository.

## Principles

Most of the rules below follow from a few principles.
Where no rule fits, apply the principle.

- Code should be understandable in isolation.
  What a value means should be visible where it is defined, not only where it is checked.
- Let the compiler catch bugs: what doesn't compile cannot fail at runtime.
  A newtype enforces its invariant once, at construction, so it never has to be checked again.
  An exhaustive match points at every place that needs to handle a new variant, whereas an `else` swallows it silently.
- Keep public APIs narrow.
  Changes to a module then stay contained and its concerns don't leak out.
- Give every fact one owner.
  A second copy, a second timer or a second computation of the same thing will eventually disagree with the first.
  The exception is performance: a copy that saves work on the per-packet path is fine if a benchmark shows the win and the copy is documented as a cache.
- Size attracts attention, so make it proportional to what matters.
  A long comment, a new abstraction or a large diff tells the reader that something important is happening before they can check.
  If it isn't, they learn to skim, including the one comment that does encode a subtle invariant.
  The goal is proportion, not minimalism: a real invariant earns a real comment.
- Reliability comes first: Firezone is a connectivity product.
  A dropped packet is retransmitted by the host's network stack, but a panic takes down the entire application or background service.
- Keep indentation low.
  Every condition that has been checked and returned from is one less thing to keep in mind while reading on.
- Test through public APIs so that the implementation can be refactored underneath.
  A test that has to change together with the implementation can encode the same bug in both.

## Code style

- Prefer a functional style (i.e. iterators) over imperative code, especially when you are expressing data transformations.
  For side-effects, imperative loops may be easier to understand.
- Prefer turbofish over explicit type-hints where the compiler cannot infer the type.
  If possible, write code where the compiler can infer the type.
- Prefer early-returns to keep the indentation of the happy-path minimal, i.e. use `let-else` instead of `if let`.
  Do cheap checks and early exits first, before mutating state or doing other work.
- Write one match-arm per distinct case, even if the bodies are identical or create slight duplication.
  Separate arms format better than combined `A | B` patterns or `matches!` guards, and each case can get its own log message.
  Arms that do nothing (`=> {}`) can be combined.
- Flatten nested conditions with match-arm guards instead of an `if` inside the arm, a `matches!` or a chain of `if let`s.
  With every combination spelled out as an arm, the compiler checks that all of them are handled.
- Match exhaustively on our own enums instead of using `if let` or `if`-`else`.
  Adding a variant should produce a compile error in every place that needs to handle it, not silently fall into the `else`.
- Split a compound boolean condition into separate branches when the cases are actually different, even if that duplicates a line.
  There is less boolean logic to parse and each case can get its own log or error message.
- Order functions within a module from high to low priority: Public API first, then sorted roughly in order of how they are called.
  Scrolling further down should be roughly equivalent to drilling down into details as to how the module works.
  This also applies to test modules:
  Helper functions inside test modules should always be below their usage.
  The tests are important, the helpers are not.
- Don't end functions with expressions that evaluate to `Result`.
  Instead, assign it to another variable, use `?` and end the function with `Ok(T)`.
  This ensures error handling and failure paths are always clearly visible.
- Prefer `extract_if` over `retain` when removing entries from a collection.
  The predicate states what is removed, which takes less boolean logic to follow.
- Drain an iterator for its side-effects with `for _ in iter {}`, not with `.for_each(drop)`.
- Never use the `tokio::select!` or `futures::select!` macros.
  Their custom syntax obscures in which order things happen.
  Use `futures::future::select` and match on the `Either`, or write a helper function that polls.
- Before writing a helper, check whether `std`, a crate that is already in the dependency tree or a neighbouring module provides it.
  For example, `clap` handles defaults, environment variables and enums.
- Don't rename imports with `as`.
  Refer to the item through its module instead, e.g. `expiring_map::Event`, and name modules and types such that this reads well without stutter.
  Importing a trait `as _` and giving per-platform modules a common name (`use linux as platform`) are fine.
- Use `#[expect(...)]` instead of `#[allow(...)]` so the attribute fails once it is no longer necessary, and apply it to the smallest item possible.
  Prefix an intentionally unused binding with `_` instead of allowing `dead_code`.
- Hide platform differences behind a cross-platform API so that callers need no `#[cfg(target_os)]`.
  Give each platform a module with the same API, including a no-op or stub where a platform has nothing to do, and gate once at the module level.
  This is about platforms only: gate a call-site on a Cargo feature or `debug_assertions` directly instead of writing a stub for it.

## Naming

- Name things after what they do or what they are for, not after how they are implemented.
  Rename them when a change alters their meaning.
- Use the vocabulary that already exists: the name of the sibling function, the name of the equivalent on the other side (Client vs Gateway) or the term the protocol itself uses.
- Avoid stutter between a module and its items: `ipc::ClientMsg`, not `ipc::IpcClientMsg`.
- Follow the conventions of `std`: `into_*` consumes `self`, `with_*` takes and returns `self`, and standard traits (`Display`, `Default`, `FromStr`) replace bespoke methods.

## Types and API design

- Parse at the boundary and pass the typed value on (`Url`, `SocketAddr`, `Duration`, an enum).
  Keeping a `String` around means re-parsing it later and more error cases to handle.
- Wrap IDs, tokens and similar values in a newtype instead of passing a bare `String` around.
- Let the type say what a value means instead of giving an ordinary value a special meaning.
  Represent a missing value with `None` and a failure with `Err`, never with a placeholder such as `0` or an unspecified address.
  Use a dedicated enum instead of a `bool`, for parameters as well as return values.
- If the two cases of a parameter share no code, write two functions.
- Encode invariants in the type system: take ownership of a value that must not be used afterwards, tie values together with lifetimes, clean up in `Drop`.
  Avoid `Option` fields that are always `Some` after setup and state that can be derived from other state.
- Prefer defaults (`#[serde(default)]`, `clap`'s `default_value`, `Default`) over an `Option` that every consumer has to unwrap.
- Prefer a single owner with `&mut self` over `Arc<Mutex<T>>` and other interior mutability.
- Keep items private by default.
  Re-export a type instead of making its entire module public.
- Return values or emit events instead of accepting callbacks; callbacks don't compose.
- Don't add what nothing uses: parameters that are always passed the same value, flags, config knobs, injection seams whose only caller passes the default, API that nobody asked for.
  In the same change, remove whatever it made unnecessary: unused parameters, an `async`, a `clone`, a helper.
- Don't write migration, cleanup or compatibility code for a state that was never released.
  If nothing that shipped could have produced it, there is nothing to migrate.
- Decide between sharing and duplicating code by its reason to change.
  Code that changes for the same reason lives in one place, otherwise a later change updates one copy and misses the other.
  Code that changes for different reasons can be duplicated, even if it looks the same today.
- Inline a helper that has a single call-site and no branching: The reader pays for every indirection.

## Error handling

- Use `anyhow` and attach `.context(...)` that names the operation that failed and its target (the path, the address).
  Use `.with_context(|| format!(...))` when the message is formatted, to avoid the allocation in the happy-path.
- Define a dedicated error type only if a caller matches on it, using the `thiserror` derive.
  For a single case that a caller needs to branch on, define a unit-struct error and check for it with `any_downcast_ref`.
- Handle an error exactly once: Either propagate it with `?` or log it.
  Logging and returning an error results in duplicate logs.
- Don't make errors disappear by converting them into an `Option` or dropping the `Result`.
  Return `Result` (or `Result<Option<T>>` if "nothing" is a valid outcome) and log at the top-level.
- Return an error instead of panicking: A panic takes down the entire application or background service.
  Reserve `expect` for real invariants and use `debug_assert!` to make assumptions visible.
- Don't add retry state or a timer for a failure that the next regular attempt already surfaces.
  Let it fail; the next attempt asks again.
- Don't add a give-up timer or cooldown for a failure that the protocol's own expiry or an existing backoff already detects.
  Two deadlines for one failure disagree, and the failure surfaces twice.
- Make operations idempotent.
  Removing something that is already gone or applying the same update twice is not an error and does not deserve a warning.

## Comments

- Default to no comments; let the code speak.
  Types, function and variable names give a lot of opportunity for naming.
  Comment only a non-obvious "why" such as a hack, a workaround or an invariant, and explain it in exactly one place.
- Document the code, not the change that introduced it.
  A comment should read the same a year later to someone who never saw the diff, so avoid change-relative wording like "instead of", "now", "no longer", or "previously".
  The reason for a change belongs in the commit message, not in a code comment.
- Style doc comments after the [rustdoc guide](https://doc.rust-lang.org/rustdoc/how-to-write-documentation.html#documenting-components): a third-person, one-sentence summary (e.g. "Returns the tidied title"), followed by a blank line and further detail, with `# Examples`, `# Panics`, `# Errors` and `# Safety` sections where they apply.
- Put a comment on the item it explains (the type, the function, the match-arm), not on its use-sites or in a module header, and trim it to what that item does.
  Don't describe who calls the code or repeat the value of a constant; both go stale.
- Re-read the comments and docs of code you change.
  A comment that describes behaviour which has moved elsewhere is worse than no comment.

## Dependencies

- Enable a feature in `[workspace.dependencies]` only if it selects a backend or behaviour for the entire build, e.g. `ring` for `rustls`.
  Features that gate API are enabled by the crates that use that API, in their own `Cargo.toml`.
- In `Cargo.toml`, put a comment on the same line as the dependency so it survives sorting.

## Unsafe

- Look for an existing safe abstraction before writing `unsafe`.
  If there is none, keep the `unsafe` layer as thin as possible and build a small, safe API on top of it.
- Give every `unsafe` block a `// SAFETY:` comment that addresses the conditions listed in the `# Safety` docs of the function being called.

## Tests

- Focus on the public API of the module.
- Cover the behaviour a change introduces, not every path: one or two focused tests are usually enough.
- Follow the arrange - act - assert pattern.
- Test only our own code.
  Don't test third-party behaviour, derived `serde` impls or functions that only forward to an inner method.
  The exception are snapshot tests that lock in an API contract, such as the wire format of a message.
- Assert on observable behaviour (return values, emitted events) using the exact expected value.
  Don't compute the expectation with the code under test.
- Write one test per behaviour instead of one combined test.
  Share setup through fixtures and helpers that take what varies as a parameter.
- Build the real value a dependency produces (e.g. a `tungstenite::Error::Http`) and feed it through the public input, instead of a look-alike type or a `#[cfg(test)]` setter on a production type.
  A look-alike encodes your assumption about the dependency, which is what the test should check.
- For a deterministic RNG, use a seeded `StdRng`.
  Write your own only when the test depends on its exact output.
- For connlib behaviour that only matters in the context of packet flow, extend the `tunnel` target of the [fuzzer](tests/fuzz) (a new `Transition`, sampling a new input) instead of writing unit tests that construct `ClientState` or `GatewayState`.
  Self-contained unit tests for small components and wire formats are fine.

## Architecture

- State components such as `ClientState` and `GatewayState` are sans-IO: no IO, no reading of the clock or the environment, no spawned tasks, no `.await` and no platform-specific code.
  Inputs, including the current time, are passed in; outputs are returned or emitted as events.
- `Tunnel` and the event-loops are glue only.
  Logic belongs on the state component, even if that means a bit of duplication between Client and Gateway.
- Put logic into the component that owns the concept and hide lower-level details behind its API.
  `ClientState` should orchestrate between components, not implement their behaviour.
- Do timer-driven work in `handle_timeout` and keep `poll_*` functions trivial.
- Keep the per-packet path free of allocations and repeated lookups.
  Everywhere else, prefer the simpler design; optimisations need a benchmark.
- Expose `async fn`s and let the caller decide where they run instead of creating runtimes or threads inside a library.
- Drive a background task with a single channel and a message enum.
  It stops when the sender is dropped.
- Respect back-pressure: Wait for readiness instead of queueing more work, yielding or batching ahead of a blocked sink.

## Changes

- Keep the diff minimal: every hunk serves the purpose of the PR.
  Don't reorder, move, rename or reformat code that the change doesn't need to touch.
- Whenever the design of a change moves, re-evaluate what the earlier design introduced: abstractions, helpers, parameters, widened visibility.
  Remove everything the current design no longer needs.
- Send refactorings that prepare a feature as their own PR, ahead of the feature.
- Don't regenerate `Cargo.lock`.
  Start from the lockfile on `main` (`git checkout main -- rust/Cargo.lock`) and let `cargo` apply only what the `Cargo.toml` change requires.
