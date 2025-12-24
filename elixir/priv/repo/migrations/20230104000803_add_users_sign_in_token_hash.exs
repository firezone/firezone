defmodule Portal.Repo.Migrations.AddUsersSignInTokenHash do
  use Ecto.Migration

  def change do
    alter table(:users) do
      remove(:sign_in_token, :string)
      add(:sign_in_token_hash, :string)
    end
  end
end
