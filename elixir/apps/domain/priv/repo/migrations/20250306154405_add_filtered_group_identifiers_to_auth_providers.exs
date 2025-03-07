defmodule Domain.Repo.Migrations.AddFilteredGroupIdentifiersToAuthProviders do
  use Ecto.Migration

  def change do
    alter table(:auth_providers) do
      add(:filtered_group_identifiers, {:array, :string}, default: [])
      add(:group_filters_enabled_at, :utc_datetime_usec)
    end
  end
end
