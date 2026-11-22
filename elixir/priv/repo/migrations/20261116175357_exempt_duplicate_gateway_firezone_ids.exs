defmodule Portal.Repo.Migrations.ExemptDuplicateGatewayFirezoneIds do
  use Ecto.Migration

  # Some accounts have one gateway firezone_id in more than one site. The most
  # recently seen gateway keeps the id, and the others are exempt from the
  # unique index until their admins clean them up.
  def up do
    execute("""
    UPDATE devices AS d
    SET firezone_id_exempt = true
    FROM (
      SELECT id,
             row_number() OVER (
               PARTITION BY account_id, firezone_id
               ORDER BY last_seen_at DESC NULLS LAST, id
             ) AS rank
      FROM devices
      WHERE type = 'gateway' AND firezone_id IS NOT NULL
    ) AS ranked
    WHERE d.id = ranked.id AND ranked.rank > 1
    """)
  end

  def down, do: :ok
end
