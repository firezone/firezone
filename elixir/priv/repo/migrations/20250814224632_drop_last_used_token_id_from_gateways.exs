defmodule Portal.Repo.Migrations.DropLastUsedTokenIdFromGateways do
  use Ecto.Migration

  def change do
    alter table(:gateways) do
      remove(:last_used_token_id, references(:tokens, type: :binary_id, on_delete: :nilify_all))
    end
  end
end
