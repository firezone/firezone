defmodule FzHttp.Repo.Migrations.CreateSiteNetworkPolicies do
  use Ecto.Migration

  def change do
    create table(:site_network_policies, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))

      add(:network_policy_id, references(:network_policies, on_delete: :delete_all, type: :uuid),
        null: false
      )

      add(:site_id, references(:sites, on_delete: :delete_all, type: :uuid), null: false)

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:site_network_policies, [:network_policy_id, :site_id]))
  end
end
