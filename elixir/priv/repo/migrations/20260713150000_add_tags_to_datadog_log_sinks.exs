defmodule Portal.Repo.Migrations.AddTagsToDatadogLogSinks do
  use Ecto.Migration

  def change do
    alter table(:datadog_log_sinks) do
      add(:tags, :text)
    end
  end
end
