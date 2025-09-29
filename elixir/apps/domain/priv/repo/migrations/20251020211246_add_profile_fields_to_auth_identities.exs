defmodule Domain.Repo.Migrations.AddProfileFieldsToAuthIdentities do
  use Domain, :migration

  def change do
    alter table(:auth_identities) do
      add(:name, :text)
      add(:given_name, :text)
      add(:family_name, :text)
      add(:middle_name, :text)
      add(:nickname, :text)
      add(:preferred_username, :text)
      add(:profile, :text)
      add(:picture, :text)
    end
  end
end
