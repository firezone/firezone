defmodule FzHttp.Repo.Migrations.CreateGatewayNetworkPolicies do
  use Ecto.Migration

  def change do
    create table(:gateway_network_policies, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:gateway_id, references(:gateways, on_delete: :delete_all, type: :uuid), null: false)

      add(:network_policy_id, references(:network_policies, on_delete: :delete_all, type: :uuid),
        null: false
      )

      timestamps(type: :utc_datetime_usec)
    end

    create(index(:gateway_network_policies, [:gateway_id, :network_policy_id]))
  end
end
