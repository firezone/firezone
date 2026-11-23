defmodule Portal.Repo.Migrations.CreateDeviceCertificateAuthorities do
  use Ecto.Migration

  def change do
    create table(:device_certificate_authorities, primary_key: false) do
      add(:account_id, references(:accounts, type: :binary_id, on_delete: :delete_all),
        primary_key: true
      )

      add(:key_id, :text)
      add(:private_key, :binary)
      add(:certificate, :binary, null: false)

      timestamps(type: :timestamptz, updated_at: false)
    end

    create(
      constraint(:device_certificate_authorities, :key_id_or_private_key,
        check: "num_nonnulls(key_id, private_key) = 1"
      )
    )
  end
end
