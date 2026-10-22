defmodule Portal.Repo.Migrations.AddSingleOwnerGatewayTokens do
  use Ecto.Migration

  def change do
    alter table(:gateway_tokens) do
      add(:device_id, :binary_id)
      add(:rotated_at, :timestamptz)
    end

    # Single-owner tokens set device_id and leave site_id NULL
    execute(
      "ALTER TABLE gateway_tokens ALTER COLUMN site_id DROP NOT NULL",
      "ALTER TABLE gateway_tokens ALTER COLUMN site_id SET NOT NULL"
    )

    # Composite foreign key for (account_id, device_id) -> devices(account_id, id).
    # Deleting a gateway deletes its tokens, which disconnects it via the delete hook.
    execute(
      """
      ALTER TABLE gateway_tokens
      ADD CONSTRAINT gateway_tokens_device_id_fkey
      FOREIGN KEY (account_id, device_id) REFERENCES devices(account_id, id) ON DELETE CASCADE
      """,
      "ALTER TABLE gateway_tokens DROP CONSTRAINT gateway_tokens_device_id_fkey"
    )

    # Two-slot invariant: at most one active (rotated_at IS NULL) and one rotated
    # token per gateway. NULL device_id rows (multi-owner tokens) never collide.
    execute(
      """
      CREATE UNIQUE INDEX gateway_tokens_device_rotated_state_idx
      ON gateway_tokens (account_id, device_id, (rotated_at IS NULL))
      """,
      "DROP INDEX gateway_tokens_device_rotated_state_idx"
    )

    # A token is either multi-owner (site_id) or single-owner (device_id), never both
    create(
      constraint(:gateway_tokens, :single_or_multi_owner,
        check: "num_nonnulls(site_id, device_id) = 1"
      )
    )

    # The grace-period reaper deletes by rotated_at cutoff; the partial index
    # stays tiny since rotated tokens are few and short-lived
    create(
      index(:gateway_tokens, [:rotated_at],
        where: "rotated_at IS NOT NULL",
        name: :gateway_tokens_rotated_at_index
      )
    )

    # Pre-created single-owner gateways leave firezone_id blank until the
    # gateway reports it on first connect
    execute(
      "ALTER TABLE devices ALTER COLUMN firezone_id DROP NOT NULL",
      "ALTER TABLE devices ALTER COLUMN firezone_id SET NOT NULL"
    )
  end
end
