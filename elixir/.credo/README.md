# Custom Credo Checks

This directory contains custom Credo checks specific to the Firezone codebase.

## Available Checks

### Warning.MissingChangesetFunction

Ensures that Ecto schema modules define a `changeset/1` function that accepts an `Ecto.Changeset`.

**Rationale:** We expect the caller to be able to pass in an already-created changeset for validation, ensuring a consistent pattern across the codebase.

**Exceptions:**

- Embedded schemas (using `embedded_schema do` blocks) typically use `changeset/2` instead
- Simple schemas that don't accept user input (like audit logs, processed events, or read-only schemas) may not need a changeset function

**Example:**

```elixir
defmodule Portal.Account do
  use Ecto.Schema
  import Ecto.Changeset

  schema "accounts" do
    field :name, :string
    timestamps()
  end

  def changeset(changeset) do
    changeset
    |> validate_required([:name])
    |> validate_length(:name, min: 3, max: 64)
  end
end
```

### Warning.ActionFallbackUsage

Prevents the use of `action_fallback` macro in controllers. Use explicit error handling with `Error.handle/2` instead.

### Warning.UnsafeRepoUsage

Restricts direct `Portal.Repo` calls to specific contexts (Portal.Safe module, seeds, tests, migrations).

### Warning.SafeCallsOutsideDatabaseModule

Validates that database functions are properly isolated.

### Warning.MissingDatabaseAlias

Ensures proper Portal.Safe aliasing in modules that need it.

### Warning.CrossModuleDatabaseCall

Prevents cross-module database operations to maintain proper boundaries.

## Running Checks

```bash
# Run all Credo checks
mix credo --strict

# Run only custom checks
mix credo --only MissingChangesetFunction

# Run Credo in CI
# Checks are automatically run in the GitHub Actions workflow
```

## Adding New Custom Checks

1. Create a new module in `.credo/check/warning/` or `.credo/check/consistency/`
2. Implement the check following the pattern of existing checks
3. Add the check to `.credo.exs` in both the `requires` and `checks.enabled` sections
4. Test the check on relevant code
5. Document the check in this README
