defmodule Domain.Repo.Migrations.AddEndSessionUriToTokens do
  use Domain, :migration

  def change do
    alter table(:tokens) do
      add :end_session_uri, :text
    end
  end
end
