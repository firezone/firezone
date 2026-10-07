defmodule Portal.Repo.Migrations.AddDisabledByDirectoryIdToActors do
  @moduledoc """
  Records which directory disabled an actor, so a sync re-enables only the
  actors it disabled itself and never one an admin disabled.

  The column starts out NULL everywhere, so the constraints are added NOT VALID
  and validated afterwards without blocking writes for the scan. The partial
  index keeps the ON DELETE SET NULL from scanning actors when a directory is
  deleted.
  """
  use Ecto.Migration

  @disable_ddl_transaction true

  def change do
    alter table(:actors) do
      add(
        :disabled_by_directory_id,
        references(:directories,
          type: :binary_id,
          with: [account_id: :account_id],
          on_delete: {:nilify, [:disabled_by_directory_id]},
          validate: false
        )
      )
    end

    create(
      constraint(:actors, :disabled_by_directory_requires_disabled,
        check: "disabled_by_directory_id IS NULL OR is_disabled",
        validate: false
      )
    )

    create(
      index(:actors, [:account_id, :disabled_by_directory_id],
        name: :actors_disabled_by_directory_id_index,
        where: "disabled_by_directory_id IS NOT NULL",
        concurrently: true
      )
    )

    execute("ALTER TABLE actors VALIDATE CONSTRAINT actors_disabled_by_directory_id_fkey", "")
    execute("ALTER TABLE actors VALIDATE CONSTRAINT disabled_by_directory_requires_disabled", "")
  end
end
