defmodule Portal.Repo.Migrations.AddDevicesAttestedIdentityIndexes do
  use Ecto.Migration

  @disable_ddl_transaction true

  def change do
    create_if_not_exists(
      unique_index(:devices, [:account_id, :last_attested_mdm_device_id],
        where: "last_attested_mdm_device_id IS NOT NULL",
        concurrently: true
      )
    )

    create_if_not_exists(
      unique_index(:devices, [:account_id, :last_attested_cert_issuer, :last_attested_cert_serial],
        where: "last_attested_cert_issuer IS NOT NULL AND last_attested_cert_serial IS NOT NULL",
        name: :devices_account_id_cert_issuer_serial_index,
        concurrently: true
      )
    )
  end
end
