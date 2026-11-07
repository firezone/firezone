defmodule Portal.Repo.Migrations.AddManagedByToActors do
  @moduledoc """
  Tells the actors the system provisions and owns, such as the service account
  behind infrastructure devices, apart from the account's own. Every existing
  actor belongs to its account.
  """
  use Ecto.Migration

  def change do
    alter table(:actors) do
      add(:managed_by, :string, null: false, default: "account")
    end

    create(
      constraint(:actors, :actors_managed_by_is_valid,
        check: "managed_by IN ('account', 'system')"
      )
    )

    # Only system actors are ever looked up by this column, so the index
    # stays as small as the handful of rows per account it points at.
    create(
      index(:actors, [:account_id, :managed_by],
        where: "managed_by = 'system'",
        name: :actors_account_id_managed_by_index
      )
    )
  end
end
