defmodule Portal.Repo.Migrations.CreateSiteDevices do
  use Ecto.Migration

  def change do
    create table(:site_devices, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(
        :site_id,
        references(:sites,
          with: [account_id: :account_id],
          type: :binary_id,
          on_delete: :delete_all
        ),
        null: false,
        primary_key: true
      )

      add(
        :device_id,
        references(:devices,
          with: [account_id: :account_id],
          type: :binary_id,
          on_delete: :delete_all
        ),
        null: false,
        primary_key: true
      )

      timestamps(updated_at: false)
    end
  end
end
