defmodule Domain.Repo.Migrations.AddKeyRegeneratedAt do
  use Ecto.Migration

  def change do
    alter table(:devices) do
      add(:key_regenerated_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end
  end
end
