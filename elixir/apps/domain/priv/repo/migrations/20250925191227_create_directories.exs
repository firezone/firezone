defmodule Domain.Repo.Migrations.CreateDirectories do
  use Domain, :migration

  def change do
    create table(:directories, primary_key: false) do
      account(primary_key: true)

      add(:id, :binary_id, primary_key: true)
      add(:type, :string, null: false)

      subject_trail()
      timestamps()
    end

    create(index(:directories, [:account_id, :type], unique: true, where: "type = 'firezone'"))
  end
end
