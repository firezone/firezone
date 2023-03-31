defmodule Domain.Repo.Migrations.AddStatsToDevices do
  use Ecto.Migration

  def change do
    alter table(:devices) do
      add(:rx_bytes, :bigint)
      add(:tx_bytes, :bigint)
    end

    rename(table(:devices), :last_seen_at, to: :latest_handshake)
  end
end
