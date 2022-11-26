defmodule FzHttp.Repo.Migrations.AddPlatformToDevices do
  use Ecto.Migration

  def change do
    alter table(:devices) do
      add(:client_platform, :int)
    end
  end
end
