defmodule Domain.Repo.Migrations.AddFlowsTokens do
  use Ecto.Migration

  @assoc_opts [type: :binary_id, on_delete: :nilify_all]

  def change do
    execute("DELETE FROM flows;")

    alter table(:flows) do
      add(:token_id, references(:tokens, @assoc_opts), null: false)
    end
  end
end
