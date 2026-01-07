defmodule Portal.Repo.Migrations.AddClientsLastUsedTokenId do
  use Ecto.Migration

  def change do
    execute("DELETE FROM flows;")
    execute("DELETE FROM flow_activities;")
    execute("DELETE FROM clients;")

    alter table(:clients) do
      add(:last_used_token_id, references(:tokens, type: :binary_id, on_delete: :nilify_all),
        null: false
      )
    end
  end
end
