defmodule Domain.Repo.Migrations.AddIncludedGroupsToAuthProviders do
  use Ecto.Migration

  def change do
    alter table(:auth_providers) do
      add(:included_groups, {:array, :string}, default: [])
      add(:group_filters_enabled_at, :utc_datetime_usec)
    end
  end
end
