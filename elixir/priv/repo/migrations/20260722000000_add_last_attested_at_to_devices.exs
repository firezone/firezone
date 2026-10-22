defmodule Portal.Repo.Migrations.AddLastAttestedAtToDevices do
  @moduledoc """
  Adds `last_attested_at`: when the device last proved possession of an
  MDM-provisioned client certificate. Like the other `last_attested_*`
  columns it records point-in-time history and is never cleared by the
  session flush; whether the CURRENT session proved possession is live
  connection state (the `attested?` presence attribute), not row state.
  Nullable with no default, so the column add is metadata-only.
  """
  use Ecto.Migration

  def change do
    alter table(:devices) do
      add(:last_attested_at, :timestamptz)
    end
  end
end
