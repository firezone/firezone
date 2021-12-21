defmodule FzHttp.Repo.Migrations.AddRoleToUsers do
  use Ecto.Migration

  @create_query "CREATE TYPE role_enum AS ENUM ('unprivileged', 'admin')"
  @drop_query "DROP TYPE role_enum"

  def change do
    execute(@create_query, @drop_query)

    alter table(:users) do
      add :role, :role_enum, default: "unprivileged", null: false
    end

    # Make existing admin the admin if exists. Admin is most likely the first created user.
    flush()

    execute """
    UPDATE users SET role = 'admin' WHERE id IN (
        SELECT id FROM (
            SELECT id FROM users
            ORDER BY inserted_at ASC
            LIMIT 1
        ) tmp
    )
    """
  end
end
