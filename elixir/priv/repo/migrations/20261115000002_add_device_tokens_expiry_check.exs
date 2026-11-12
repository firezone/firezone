defmodule Portal.Repo.Migrations.AddDeviceTokensExpiryCheck do
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout TO '2s'")

    create(
      constraint(:device_tokens, :device_tokens_unbound_expires,
        check: "site_id IS NOT NULL OR device_id IS NOT NULL OR expires_at IS NOT NULL",
        validate: false
      )
    )
  end

  def down do
    drop(constraint(:device_tokens, :device_tokens_unbound_expires))
  end
end
