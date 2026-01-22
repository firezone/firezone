defmodule Portal.Repo.Migrations.RenameFkConstraintsForAssocConstraint do
  use Ecto.Migration

  @doc """
  Renames FK constraints to match Ecto's default assoc_constraint naming convention.

  This allows us to use `assoc_constraint(:assoc_name)` without explicit `:name` options,
  since Ecto derives the constraint name as `{table}_{assoc_name}_id_fkey`.

  These are metadata-only operations that don't require table locks.
  """

  def up do
    # client_tokens was renamed from tokens, but FK constraints kept old names
    execute(
      "ALTER TABLE client_tokens RENAME CONSTRAINT tokens_actor_id_fkey TO client_tokens_actor_id_fkey"
    )

    execute(
      "ALTER TABLE client_tokens RENAME CONSTRAINT tokens_auth_provider_id_fkey TO client_tokens_auth_provider_id_fkey"
    )

    # resources has a non-standard composite FK name
    execute(
      "ALTER TABLE resources RENAME CONSTRAINT resources_account_id_site_id_fkey TO resources_site_id_fkey"
    )
  end

  def down do
    execute(
      "ALTER TABLE client_tokens RENAME CONSTRAINT client_tokens_actor_id_fkey TO tokens_actor_id_fkey"
    )

    execute(
      "ALTER TABLE client_tokens RENAME CONSTRAINT client_tokens_auth_provider_id_fkey TO tokens_auth_provider_id_fkey"
    )

    execute(
      "ALTER TABLE resources RENAME CONSTRAINT resources_site_id_fkey TO resources_account_id_site_id_fkey"
    )
  end
end
