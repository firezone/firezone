defmodule FzHttp.Repo.Migrations.CreateNetworkPolicies do
  use Ecto.Migration

  @create_query "CREATE TYPE default_action_enum AS ENUM ('accept', 'deny')"
  @drop_query "DROP TYPE default_action_enum"

  def change do
    execute(@create_query, @drop_query)

    create table(:network_policies, primary_key: false) do
      add(:id, :uuid, primary_key: true, default: fragment("gen_random_uuid()"))
      add(:default_action, :default_action_enum, default: "deny", null: false)

      timestamps(type: :utc_datetime_usec)
    end
  end
end
