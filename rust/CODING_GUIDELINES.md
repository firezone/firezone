# Rust coding guidelines

Rules for all Rust code in this repository.

## Code style

- Prefer a functional style (i.e. iterators) over imperative code, especially when you are expressing data transformations.
  For side-effects, imperative loops may be easier to understand.
- Prefer turbofish over explicit type-hints where the compiler cannot infer the type.
  If possible, write code where the compiler can infer the type.
- Prefer early-returns to keep the indentation of the happy-path minimal, i.e. use `let-else` instead of `if let`.
- Write one match-arm per distinct case, even if the bodies are identical or create slight duplication.
  Separate arms format better and read clearer than combined `A | B` patterns or `matches!` guards.
- Order functions within a module from high to low priority: Public API first, then sorted roughly in order of how they are called.
  Scrolling further down should be roughly equivalent to drilling down into details as to how the module works.
  This also applies to test modules:
  Helper functions inside test modules should always be below their usage.
  The tests are important, the helpers are not.
- Don't end functions with expressions that evaluate to `Result`.
  Instead, assign it to another variable, use `?` and end the function with `Ok(T)`.
  This ensures error handling and failure paths are always clearly visible.

## Comments

- Default to no comments; let the code speak.
  Types, function and variable names give a lot of opportunity for naming.
  Comment only a non-obvious "why" such as a hack, a workaround or an invariant, and explain it in exactly one place.
- Document the code, not the change that introduced it.
  A comment should read the same a year later to someone who never saw the diff, so avoid change-relative wording like "instead of", "now", "no longer", or "previously".
  The reason for a change belongs in the commit message, not in a code comment.
- Style doc comments after the [rustdoc guide](https://doc.rust-lang.org/rustdoc/how-to-write-documentation.html#documenting-components): a third-person, one-sentence summary (e.g. "Returns the tidied title"), followed by a blank line and further detail, with `# Examples`, `# Panics`, `# Errors` and `# Safety` sections where they apply.

## Tests

- Focus on the public API of the module.
- Cover the behaviour a change introduces, not every path: one or two focused tests are usually enough.
- Follow the arrange - act - assert pattern.
