defmodule Portal.Repo.Migrations.DeleteRsaDeviceCertificateAuthorities do
  use Ecto.Migration

  # Device CAs are now P-256. The RSA CAs made before have issued nothing, and the backfill makes new ones.
  def up do
    execute("DELETE FROM device_certificate_authorities")
  end

  def down, do: :ok
end
