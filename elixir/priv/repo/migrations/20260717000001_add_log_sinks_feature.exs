defmodule Portal.Repo.Migrations.AddLogSinksFeature do
  use Ecto.Migration

  def change do
    execute(
      "INSERT INTO features (feature, enabled) VALUES ('log_sinks', false)",
      "DELETE FROM features WHERE feature = 'log_sinks'"
    )
  end
end
