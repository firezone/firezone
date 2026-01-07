defmodule Portal.Repo.Migrations.AllowNullLastUsedTokenIdOnClients do
  use Ecto.Migration

  def up do
    alter table(:clients) do
      modify(:last_used_token_id, :uuid, null: true)
    end
  end

  def down do
    alter table(:clients) do
      modify(:last_used_token_id, :uuid, null: false)
    end
  end
end
