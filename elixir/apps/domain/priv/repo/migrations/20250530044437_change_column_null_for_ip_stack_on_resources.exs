defmodule Domain.Repo.Migrations.ChangeColumnNullForIpStackOnResources do
  use Ecto.Migration

  def up do
    alter table(:resources) do
      modify(:ip_stack, :string, null: false)
    end
  end

  def down do
    alter table(:resources) do
      modify(:ip_stack, :string, null: true)
    end
  end
end
