defmodule Portal.Repo.Migrations.AddActorIssuerUniqueIndexToExternalIdentities do
  use Ecto.Migration

  @disable_ddl_transaction true

  # Enforces one external identity per (account_id, actor_id, issuer). directory_id
  # has no bearing on identity uniqueness.
  #
  # Requires the dedup migration (20260624000001) to have removed all existing
  # violations, and the sync/interactive upserts to recycle the actor's identity
  # by (account_id, actor_id, issuer) rather than by directory_id, or the next
  # sync would insert a fresh row and trip this constraint.
  #
  # The previous partial unique index on (account_id, actor_id, directory_id) is
  # subsumed by this one: a directory has a single issuer, so any pair it
  # forbade (same actor + directory) is also forbidden here, regardless of
  # directory_id.
  def up do
    create_if_not_exists(
      index(:external_identities, [:account_id, :actor_id, :issuer],
        unique: true,
        concurrently: true
      )
    )

    drop_if_exists(
      index(:external_identities, [:account_id, :actor_id, :directory_id],
        name: :external_identities_account_id_actor_id_directory_id_index,
        concurrently: true
      )
    )
  end

  def down do
    create_if_not_exists(
      index(:external_identities, [:account_id, :actor_id, :directory_id],
        unique: true,
        where: "directory_id IS NOT NULL",
        name: :external_identities_account_id_actor_id_directory_id_index,
        concurrently: true
      )
    )

    drop_if_exists(
      index(:external_identities, [:account_id, :actor_id, :issuer], concurrently: true)
    )
  end
end
