defmodule Portal.Repo.Migrations.AddConfigTokenToDevices do
  use Ecto.Migration

  def change do
    alter table("devices") do
      add(:config_token, :string)
      add(:config_token_expires_at, :utc_datetime_usec)
    end

    create(unique_index(:devices, :config_token))
  end
end
