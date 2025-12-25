defmodule Portal.Repo.Migrations.AddFlowActivities do
  use Ecto.Migration

  @assoc_opts [type: :binary_id, on_delete: :delete_all]

  def change do
    create table(:flow_activities, primary_key: false) do
      add(:id, :uuid, primary_key: true)

      add(:window_started_at, :utc_datetime_usec, null: false)
      add(:window_ended_at, :utc_datetime_usec, null: false)

      add(:destination, :string, null: false)
      add(:rx_bytes, :bigint, null: false)
      add(:tx_bytes, :bigint, null: false)

      add(:flow_id, references(:flows, @assoc_opts), null: false)
      add(:account_id, references(:accounts, @assoc_opts), null: false)
    end

    execute("""
    CREATE UNIQUE INDEX flow_activities_account_id_flow_id_window_destination_index ON flow_activities
    USING BTREE (account_id, flow_id, window_started_at, window_ended_at, destination);
    """)

    execute("""
    CREATE INDEX flow_activities_account_id_flow_id_window_index ON flow_activities
    USING BTREE (account_id, flow_id, window_started_at ASC);
    """)

    execute("""
    CREATE INDEX flow_activities_account_id_window_index ON flow_activities
    USING BTREE (account_id, window_started_at ASC);
    """)
  end
end
