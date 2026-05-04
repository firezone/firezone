defmodule Portal.Repo.Migrations.CreateDeviceTrustAnchors do
  use Ecto.Migration

  def change do
    create table(:device_trust_anchors, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:id, :binary_id, null: false, primary_key: true)
      add(:name, :string, null: false)
      add(:certs, {:array, :binary}, null: false, default: [])

      timestamps(type: :utc_datetime_usec)
    end

    create(
      unique_index(:device_trust_anchors, [:account_id, :name],
        name: :device_trust_anchors_account_id_name_index
      )
    )
  end
end
