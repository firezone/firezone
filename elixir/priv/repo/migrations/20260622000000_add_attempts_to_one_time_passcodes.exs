defmodule Portal.Repo.Migrations.AddAttemptsToOneTimePasscodes do
  use Ecto.Migration

  def change do
    alter table(:one_time_passcodes) do
      add(:attempts, :integer, null: false, default: 0)
    end
  end
end
