defmodule Portal.Repo.Migrations.CreateTrustAnchors do
  use Ecto.Migration

  def change do
    create table(:trust_anchors, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:id, :binary_id, null: false, primary_key: true)
      add(:name, :string, null: false)

      timestamps()
    end

    create(
      unique_index(:trust_anchors, [:account_id, :name],
        name: :trust_anchors_account_id_name_index
      )
    )

    create table(:trust_anchor_certificates, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        null: false,
        primary_key: true
      )

      add(:id, :binary_id, null: false, primary_key: true)

      add(
        :trust_anchor_id,
        references(:trust_anchors,
          type: :binary_id,
          on_delete: :delete_all,
          with: [account_id: :account_id]
        ),
        null: false
      )

      add(:pem, :text, null: false)
      add(:fingerprint, :string, null: false)

      timestamps()
    end

    create(index(:trust_anchor_certificates, [:account_id, :trust_anchor_id]))

    create(
      unique_index(:trust_anchor_certificates, [:account_id, :fingerprint],
        name: :trust_anchor_certificates_account_id_fingerprint_index
      )
    )
  end
end
