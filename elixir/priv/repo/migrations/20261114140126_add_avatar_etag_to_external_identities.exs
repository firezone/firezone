defmodule Portal.Repo.Migrations.AddAvatarEtagToExternalIdentities do
  use Ecto.Migration

  def change do
    alter table(:external_identities) do
      add(:directory_picture, :text)
      add(:avatar_etag, :text)
      add(:avatar_source, :text)
    end
  end
end
