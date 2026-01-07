defmodule Portal.Repo.Migrations.AddAccountSlugs do
  use Ecto.Migration

  def change do
    alter table(:accounts) do
      add(:slug, :string)
      add(:deleted_at, :utc_datetime_usec)
    end

    create(unique_index(:accounts, [:slug], where: "deleted_at IS NULL"))
  end
end
