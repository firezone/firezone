defmodule Portal.Repo.Migrations.RenameClientsStartPagePreference do
  @moduledoc """
  Moves the saved landing-page choice to the page's new name.

  An admin who picked the Clients page stored `clients`, which is no longer one
  of the values the preference accepts, so without this their portal would fall
  back to Sites on the next sign-in.
  """
  use Ecto.Migration

  def up do
    execute("""
    UPDATE actors
    SET preferences = jsonb_set(preferences, '{start_page}', '"devices"')
    WHERE preferences->>'start_page' = 'clients'
    """)
  end

  def down do
    execute("""
    UPDATE actors
    SET preferences = jsonb_set(preferences, '{start_page}', '"clients"')
    WHERE preferences->>'start_page' = 'devices'
    """)
  end
end
