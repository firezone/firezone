defmodule Portal.Repo.Migrations.MigrateDnsResourcePatterns do
  use Ecto.Migration

  def change do
    execute("""
    UPDATE resources
    SET address = replace(replace(address, '*', '**'), '?', '*')
    WHERE type = 'dns'
    """)
  end
end
