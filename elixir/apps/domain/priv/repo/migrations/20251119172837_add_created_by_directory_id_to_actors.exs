defmodule Domain.Repo.Migrations.AddCreatedByDirectoryIdToActors do
  use Ecto.Migration

  def change do
    alter table(:actors) do
      add(:created_by_directory_id, :binary_id)
    end

    create(
      index(:actors, [:created_by_directory_id], name: :actors_created_by_directory_id_index)
    )
  end
end
