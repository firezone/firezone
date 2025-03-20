defmodule Domain.Repo.Migrations.AddIncludedGroupsToAuthProviders do
  use Ecto.Migration

  def change do
    alter table(:auth_providers) do
      # NULLable since we want to distinguish between disabled, and enabled yet empty
      add(:included_groups, {:array, :string})
    end
  end
end
