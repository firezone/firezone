defmodule FzHttp.Repo.Migrations.AddRoleToUsers do
  use Ecto.Migration

  @create_query "CREATE TYPE role_enum AS ENUM ('unprivileged', 'admin')"
  @drop_query "DROP TYPE role_enum"

  def change do
    execute(@create_query, @drop_query)

    alter table(:users) do
      add(:role, :role_enum, default: "unprivileged", null: false)
    end

    # Make existing admin the admin if exists. Admin is most likely the first created user.
    flush()

    admin_email = System.get_env("ADMIN_EMAIL") || System.get_env("DEFAULT_ADMIN_EMAIL")

    if admin_email do
      execute("UPDATE users SET role = 'admin' WHERE email = '#{admin_email}'")
    end
  end
end
