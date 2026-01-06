defmodule Portal.Repo.Migrations.AddIdentityEmailColumn do
  use Ecto.Migration

  def change do
    alter table(:auth_identities) do
      add(:email, :citext)
    end
  end
end
