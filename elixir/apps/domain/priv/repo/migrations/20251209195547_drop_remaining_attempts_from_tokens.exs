defmodule Domain.Repo.Migrations.DropRemainingAttemptsFromTokens do
  use Ecto.Migration

  def change do
    alter table(:tokens) do
      remove(:remaining_attempts)
    end
  end
end
