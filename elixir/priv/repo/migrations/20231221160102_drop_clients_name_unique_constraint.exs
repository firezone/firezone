defmodule Portal.Repo.Migrations.DropClientsNameUniqueConstraint do
  use Ecto.Migration

  def change do
    execute("DROP INDEX clients_account_id_actor_id_name_index")
  end
end
