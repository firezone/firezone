defmodule Portal.Repo.Migrations.CreateBannersTable do
  use Ecto.Migration

  def change do
    create(table(:banners, primary_key: false)) do
      add(:message, :text, null: false)
    end
  end
end
