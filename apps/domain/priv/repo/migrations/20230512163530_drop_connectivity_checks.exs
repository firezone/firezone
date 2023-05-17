defmodule Domain.Repo.Migrations.DropConnectivityChecks do
  use Ecto.Migration

  def change do
    drop(table(:connectivity_checks))
  end
end
