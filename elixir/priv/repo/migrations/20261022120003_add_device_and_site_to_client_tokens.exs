defmodule Portal.Repo.Migrations.AddDeviceAndSiteToClientTokens do
  @moduledoc """
  Client tokens take over what gateway tokens could do: a token may be bound
  to one pre-created device, with rotation and a grace period, or may name a
  site that a device created on first connect joins. Bound tokens have no
  expiry of their own, so `expires_at` becomes optional.
  """
  use Ecto.Migration

  def change do
    alter table(:client_tokens) do
      add(:device_id, :binary_id)
      add(:site_id, :binary_id)
      add(:rotated_at, :timestamptz)
    end

    execute(
      "ALTER TABLE client_tokens ALTER COLUMN expires_at DROP NOT NULL",
      "ALTER TABLE client_tokens ALTER COLUMN expires_at SET NOT NULL"
    )

    # Deleting the device deletes its tokens, which disconnects it via the delete hook.
    execute(
      """
      ALTER TABLE client_tokens
      ADD CONSTRAINT client_tokens_device_id_fkey
      FOREIGN KEY (account_id, device_id) REFERENCES devices(account_id, id) ON DELETE CASCADE
      """,
      "ALTER TABLE client_tokens DROP CONSTRAINT client_tokens_device_id_fkey"
    )

    execute(
      """
      ALTER TABLE client_tokens
      ADD CONSTRAINT client_tokens_site_id_fkey
      FOREIGN KEY (account_id, site_id) REFERENCES sites(account_id, id) ON DELETE CASCADE
      """,
      "ALTER TABLE client_tokens DROP CONSTRAINT client_tokens_site_id_fkey"
    )

    # A token is bound to a device, or joins a site, or neither; never both.
    create(
      constraint(:client_tokens, :client_tokens_device_or_site,
        check: "num_nonnulls(device_id, site_id) <= 1"
      )
    )

    # Two-slot invariant: at most one active (rotated_at IS NULL) and one
    # rotated token per device.
    execute(
      """
      CREATE UNIQUE INDEX client_tokens_device_rotated_state_idx
      ON client_tokens (account_id, device_id, (rotated_at IS NULL))
      WHERE device_id IS NOT NULL
      """,
      "DROP INDEX client_tokens_device_rotated_state_idx"
    )

    create(
      index(:client_tokens, [:account_id, :site_id],
        where: "site_id IS NOT NULL",
        name: :client_tokens_account_id_site_id_index
      )
    )

    # The grace-period reaper deletes by rotated_at cutoff; the partial index
    # stays tiny since rotated tokens are few and short-lived.
    create(
      index(:client_tokens, [:rotated_at],
        where: "rotated_at IS NOT NULL",
        name: :client_tokens_rotated_at_index
      )
    )
  end
end
