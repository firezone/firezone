defmodule Portal.Repo.Migrations.RemoveMFAMethods do
  use Ecto.Migration

  def change do
    drop(table(:mfa_methods))
  end
end
