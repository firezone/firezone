defmodule FzHttp.Repo.Migrations.AddPostScriptsToSites do
  use Ecto.Migration

  def change do
    alter table(:sites) do
      add(:post_scripts, :text, default: "{}")
    end
    alter table(:devices) do
      add(:use_site_post_scripts, :boolean, default: true, null: false)
      add(:post_scripts, :text, default: "{}")
    end
  end
end
