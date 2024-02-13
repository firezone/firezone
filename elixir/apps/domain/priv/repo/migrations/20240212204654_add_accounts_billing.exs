defmodule Domain.Repo.Migrations.AddAccountsBilling do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      add(:features, :map, default: %{}, null: false)
      add(:limits, :map, default: %{}, null: false)
      add(:config, :map, default: %{}, null: false)
      add(:external_ids, :map, default: %{}, null: false)

      add(:disabled_reason, :string)
      add(:disabled_at, :utc_datetime_usec)
    end
  end
end
