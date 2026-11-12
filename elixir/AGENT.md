# AI agent rules for Firezone Elixir code

## Public functions and duplication

We prefer a small amount of copied code over a shared function that callers do not need.
A wrong abstraction costs more than a copy.

- A `def` MUST have at least two callers in other modules.
  Tests do not count as callers.
- A function with one caller is a `defp` in the module that calls it.
  Do not move it into another module "for tidiness" or for a caller that may come later.
- MUST NOT change a `defp` to `def` only so that a test can call it.
  Test it through the public function that uses it.
- Callbacks (`@impl`), Phoenix router and controller actions, and functions called through config or captures are exempt.
- Two callers do not by themselves make a shared function correct.
  Measure a copy as its size (number of AST nodes, the "mass") multiplied by the number of copies.
  When that product is small, keep a private copy in each module.
  Extract a shared function when the product is large, or when the copies must always change together (for example security checks or encoding rules).
- `Credo.Check.Design.DuplicatedCode` in `.credo.exs` sets the upper limit.
  It reports any copy with a mass of 40 or more (the Credo default).
  When it reports a copy, extract the shared logic. Do not add a `mass_threshold`.
