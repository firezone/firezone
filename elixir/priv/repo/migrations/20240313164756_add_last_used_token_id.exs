defmodule Portal.Repo.Migrations.AddLastUsedTokenId do
  use Ecto.Migration

  def change do
    alter table(:gateways) do
      add(:last_used_token_id, references(:tokens, type: :binary_id, on_delete: :nilify_all))
    end

    alter table(:relays) do
      add(:last_used_token_id, references(:tokens, type: :binary_id, on_delete: :nilify_all))
    end
  end
end
