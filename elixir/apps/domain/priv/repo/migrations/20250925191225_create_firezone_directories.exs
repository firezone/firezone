defmodule Domain.Repo.Migrations.CreateFirezoneDirectories do
  use Domain, :migration

  def change do
    create table(:firezone_directories, primary_key: false) do
      account()

      add(:directory_id, :binary_id, null: false, primary_key: true)

      add(:jit_provisioning, :boolean, default: false, null: false)

      subject_trail()
      timestamps()
    end

    create(index(:firezone_directories, [:account_id], unique: true))

    up = """
    ALTER TABLE firezone_directories
    ADD CONSTRAINT firezone_directories_directory_id_fkey
    FOREIGN KEY (account_id, directory_id)
    REFERENCES directories(account_id, id)
    ON DELETE CASCADE
    """

    down = """
    ALTER TABLE firezone_directories
    DROP CONSTRAINT firezone_directories_directory_id_fkey
    """

    execute(up, down)
  end
end
