defmodule Portal.Repo.Migrations.AddAvatarEtagToExternalIdentities do
  use Ecto.Migration

  def change do
    alter table(:external_identities) do
      add(:avatar_etag, :text)
    end
  end
end
