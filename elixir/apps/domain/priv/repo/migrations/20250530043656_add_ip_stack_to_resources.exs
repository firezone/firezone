defmodule Domain.Repo.Migrations.AddIpStackToResources do
  use Ecto.Migration

  def up do
    alter table(:resources) do
      # will add not null after populating these
      add(:ip_stack, :string)
    end
  end

  def down do
    alter table(:resources) do
      remove(:ip_stack)
    end
  end
end
