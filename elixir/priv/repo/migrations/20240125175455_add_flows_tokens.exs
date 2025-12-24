defmodule Portal.Repo.Migrations.AddFlowsTokens do
  use Ecto.Migration

  @assoc_opts [type: :binary_id, on_delete: :nothing]

  def change do
    execute("DELETE FROM flows;")
    execute("DELETE FROM flow_activities;")

    alter table(:flows) do
      add(:token_id, references(:tokens, @assoc_opts), null: false)
    end
  end
end
