defmodule Portal.Repo.Migrations.BackfillAccountKeys do
  use Ecto.Migration

  @chars "abcdefghijklmnopqrstuvwxyz0123456789"

  def up do
    execute("""
    UPDATE accounts
    SET key = (
      SELECT string_agg(substr('#{@chars}', floor(random() * 36 + 1)::int, 1), '')
      FROM generate_series(1, 6)
    )
    WHERE key IS NULL
    """)

    alter table(:accounts) do
      modify(:key, :string, size: 6, null: false, from: {:string, size: 6, null: true})
    end
  end

  def down do
    alter table(:accounts) do
      modify(:key, :string, size: 6, null: true, from: {:string, size: 6, null: false})
    end
  end
end
