defmodule Domain.Repo.Migrations.AddDisabledAtToUser do
  use Ecto.Migration

  def change do
    alter table("users") do
      add(:disabled_at, :utc_datetime_usec)
    end
  end
end
