defmodule FzHttp.Repo.Migrations.AddLastSignedInMethodToUser do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :last_signed_in_method, :string
    end
  end
end
