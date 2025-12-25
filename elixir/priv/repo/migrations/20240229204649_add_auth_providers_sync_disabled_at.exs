defmodule Portal.Repo.Migrations.AddAuthProvidersSyncDisabledAt do
  use Ecto.Migration

  def change do
    alter table(:auth_providers) do
      add(:sync_disabled_at, :utc_datetime_usec)
    end
  end
end
