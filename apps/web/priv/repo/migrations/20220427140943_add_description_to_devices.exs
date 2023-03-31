defmodule FzHttp.Repo.Migrations.AddDescriptionToDevices do
  use Ecto.Migration

  def change do
    alter table(:devices) do
      add(:description, :text)
    end
  end
end
