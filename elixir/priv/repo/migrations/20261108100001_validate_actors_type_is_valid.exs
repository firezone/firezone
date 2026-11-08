defmodule Portal.Repo.Migrations.ValidateActorsTypeIsValid do
  use Ecto.Migration

  def up do
    execute("ALTER TABLE actors VALIDATE CONSTRAINT type_is_valid")
  end

  def down, do: :ok
end
