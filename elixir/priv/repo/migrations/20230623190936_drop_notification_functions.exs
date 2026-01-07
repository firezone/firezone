defmodule Portal.Repo.Migrations.DropNotificationFunctions do
  use Ecto.Migration

  def change do
    for table <- ["devices", "rules", "users"] do
      func = String.trim_trailing(table, "s")
      execute("DROP FUNCTION notify_#{func}_changes()")
    end
  end
end
