defmodule Portal.Repo.Migrations.AddColorToBanners do
  use Ecto.Migration

  def change do
    alter table(:banners) do
      add :color, :string, default: "warning", null: false
    end
  end
end
