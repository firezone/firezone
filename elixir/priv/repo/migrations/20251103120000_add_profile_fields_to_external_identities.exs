defmodule Portal.Repo.Migrations.AddProfileFieldsToExternalIdentities do
  use Ecto.Migration

  def change do
    alter table(:external_identities) do
      add(:name, :text)
      add(:given_name, :text)
      add(:family_name, :text)
      add(:middle_name, :text)
      add(:nickname, :text)
      add(:preferred_username, :text)
      add(:profile, :text)
      add(:picture, :text)

      # This is most likely redundant with actor's email, but we save it for completeness
      modify(:email, :text, null: true)

      # For hosting the picture internally
      add(:firezone_avatar_url, :text)
    end
  end
end
