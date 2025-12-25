defmodule Portal.Repo.Migrations.RemoveResourcesIpvxAddress do
  use Ecto.Migration

  def change do
    alter table(:resources) do
      remove(
        :ipv4,
        references(:network_addresses,
          column: :address,
          type: :inet,
          with: [account_id: :account_id]
        )
      )

      remove(
        :ipv6,
        references(:network_addresses,
          column: :address,
          type: :inet,
          with: [account_id: :account_id]
        )
      )
    end
  end
end
