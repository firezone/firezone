defmodule Portal.Repo.Migrations.DropLastUsedTokenIdFromClients do
  use Ecto.Migration

  def change do
    alter table(:clients) do
      remove(:last_used_token_id, references(:tokens, type: :binary_id, on_delete: :nilify_all))
    end
  end
end
