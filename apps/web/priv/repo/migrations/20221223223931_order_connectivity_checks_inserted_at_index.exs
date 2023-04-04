defmodule Domain.Repo.Migrations.OrderConnectivityChecksInsertedAtIndex do
  use Ecto.Migration

  def change do
    drop(index(:connectivity_checks, :inserted_at))

    execute(
      "CREATE INDEX connectivity_checks_inserted_at_index ON connectivity_checks (inserted_at DESC)"
    )
  end
end
