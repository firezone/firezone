defmodule Portal.Repo.Migrations.AddIndexToTokensExpiresAt do
  use Ecto.Migration

  def change do
    create_if_not_exists(
      index(:tokens, [:expires_at],
        where: "expires_at IS NOT NULL",
        name: :tokens_expires_at_not_null_index
      )
    )
  end
end
