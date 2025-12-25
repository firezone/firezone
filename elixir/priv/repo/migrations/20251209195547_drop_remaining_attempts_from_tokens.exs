defmodule Portal.Repo.Migrations.DropRemainingAttemptsFromTokens do
  use Ecto.Migration

  def change do
    alter table(:tokens) do
      remove(:remaining_attempts, :integer)
    end
  end
end
