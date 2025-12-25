defmodule Portal.Repo.Migrations.AddAuthProvidersGoogleWorkspaceFields do
  use Ecto.Migration

  def change do
    alter table(:auth_providers) do
      add(:adapter_state, :map, default: %{}, null: false)
      add(:provisioner, :string, null: false)
      add(:last_synced_at, :utc_datetime_usec)
    end
  end
end
