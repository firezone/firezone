defmodule Portal.Repo.Migrations.RemoveLogSinksFeature do
  use Ecto.Migration

  def change do
    execute(
      "DELETE FROM features WHERE feature = 'log_sinks'",
      "INSERT INTO features (feature, enabled) VALUES ('log_sinks', false)"
    )
  end
end
