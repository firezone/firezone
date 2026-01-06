defmodule Portal.Repo.Migrations.ChangeMfaMethodsUniqueIndex do
  use Ecto.Migration

  def change do
    drop(index(:mfa_methods, [:name], unique: true))
    create(index(:mfa_methods, [:user_id, :name], unique: true))
  end
end
