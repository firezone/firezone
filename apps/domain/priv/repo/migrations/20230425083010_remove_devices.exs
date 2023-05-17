defmodule Domain.Repo.Migrations.RemoveDevices do
  use Ecto.Migration

  def change do
    drop(table(:devices))
  end
end
