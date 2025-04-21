defmodule Domain.Repo.Migrations.CreateNameFieldsOnIdentities do
  use Ecto.Migration

  def change do
    # TODO:
    # Create name fields on identities to save information retrieved from directories.
    # At the time this migration was created, we don't display these in the UI, but we
    # will in the future to allow sorting / filtering by last name. We want to keep
    # the data in the database for that reason.

  end
end
