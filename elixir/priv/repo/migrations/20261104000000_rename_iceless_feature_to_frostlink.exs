defmodule Portal.Repo.Migrations.RenameIcelessFeatureToFrostlink do
  use Ecto.Migration

  def up do
    execute("""
    UPDATE accounts
    SET features = (features - 'iceless') || jsonb_build_object('frostlink', features->'iceless')
    WHERE features ? 'iceless'
    """)
  end

  def down do
    execute("""
    UPDATE accounts
    SET features = (features - 'frostlink') || jsonb_build_object('iceless', features->'frostlink')
    WHERE features ? 'frostlink'
    """)
  end
end
