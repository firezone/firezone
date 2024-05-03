defmodule Domain.Repo.Migrations.ResetTrafficFilters do
  use Ecto.Migration

  def change do
    execute(~S"""
      UPDATE resources
      SET filters = '[]'
      WHERE filters = '[{"ports":[],"protocol":"all"}]'
    """)
  end
end
