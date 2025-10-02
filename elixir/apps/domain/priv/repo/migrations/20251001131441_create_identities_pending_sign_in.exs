defmodule Domain.Repo.Migrations.CreateIdentitiesPendingSignIn do
  use Domain, :migration

  def change do
    create table(:identities_pending_sign_in, primary_key: false) do
      account(primary_key: true)

      add(:directory_id, :binary_id, null: false, primary_key: true)
      add(:email, :citext, null: false, primary_key: true)

      subject_trail()
      timestamps()
    end

    up = """
    ALTER TABLE identities_pending_sign_in
    ADD CONSTRAINT identities_pending_sign_in_account_directory_fk
    FOREIGN KEY (account_id, directory_id)
    REFERENCES directories(account_id, id)
    ON DELETE CASCADE
    """

    down = """
    ALTER TABLE identities_pending_sign_in
    DROP CONSTRAINT identities_pending_sign_in_account_directory_fk
    """

    execute(up, down)
  end
end
