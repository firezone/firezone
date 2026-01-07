defmodule Portal.Repo.Migrations.MigratePksToUuid do
  use Ecto.Migration

  def change do
    ## connectivity_checks
    alter table("connectivity_checks") do
      remove(:id)
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
    end

    ## devices
    execute("DROP INDEX devices_uuid_index")
    rename(table("devices"), :id, to: :id_tmp)
    rename(table("devices"), :uuid, to: :id)

    alter table("devices") do
      modify(:id, :binary_id, primary_key: true)
      remove(:id_tmp)
    end

    ## rules
    execute("DROP INDEX rules_uuid_index")
    rename(table("rules"), :id, to: :id_tmp)
    rename(table("rules"), :uuid, to: :id)

    alter table("rules") do
      modify(:id, :binary_id, primary_key: true)
      remove(:id_tmp)
    end

    ## oidc_connections
    alter table("oidc_connections") do
      remove(:id)
      add(:id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()"))
    end

    ## users
    rename(table("users"), :id, to: :id_tmp)
    rename(table("users"), :uuid, to: :id)

    ### devices refs to users
    rename(table("devices"), :user_id, to: :user_id_tmp)

    execute(
      "ALTER TABLE devices RENAME CONSTRAINT devices_user_id_fkey TO devices_user_id_tmp_fkey"
    )

    alter table("devices") do
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all))
    end

    execute(
      "UPDATE devices SET user_id = (SELECT users.id FROM users WHERE users.id_tmp = devices.user_id_tmp)"
    )

    execute("ALTER TABLE devices ALTER COLUMN user_id SET NOT NULL")

    alter table("devices") do
      remove(:user_id_tmp)
    end

    create(index(:devices, [:user_id]))
    create(unique_index(:devices, [:user_id, :name]))

    ### rules refs to users
    rename(table("rules"), :user_id, to: :user_id_tmp)

    execute("ALTER TABLE rules RENAME CONSTRAINT rules_user_id_fkey TO rules_user_id_tmp_fkey")

    alter table("rules") do
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all))
    end

    execute(
      "UPDATE rules SET user_id = (SELECT users.id FROM users WHERE users.id_tmp = rules.user_id_tmp)"
    )

    execute("""
    ALTER TABLE rules
    DROP CONSTRAINT destination_overlap_excl
    """)

    execute("""
    ALTER TABLE rules
    ADD CONSTRAINT destination_overlap_excl
    EXCLUDE USING gist (destination inet_ops WITH &&, action WITH =)
    WHERE (user_id IS NULL AND port_range IS NULL)
    """)

    execute("""
    ALTER TABLE rules
    DROP CONSTRAINT destination_overlap_excl_port
    """)

    execute("""
    ALTER TABLE rules
    ADD CONSTRAINT destination_overlap_excl_port
    EXCLUDE USING gist (destination inet_ops WITH &&, action WITH =, port_range WITH &&, port_type WITH =)
    WHERE (user_id IS NULL AND port_range IS NOT NULL)
    """)

    execute("""
    ALTER TABLE rules
    DROP CONSTRAINT destination_overlap_excl_usr_rule
    """)

    execute("""
    ALTER TABLE rules
    ADD CONSTRAINT destination_overlap_excl_usr_rule
    EXCLUDE USING gist (destination inet_ops WITH &&, user_id WITH =, action WITH =)
    WHERE (user_id IS NOT NULL AND port_range IS NULL)
    """)

    execute("""
    ALTER TABLE rules
    DROP CONSTRAINT destination_overlap_excl_usr_rule_port
    """)

    execute("""
    ALTER TABLE rules
    ADD CONSTRAINT destination_overlap_excl_usr_rule_port
    EXCLUDE USING gist (destination inet_ops WITH &&, user_id WITH =, action WITH =, port_range WITH &&, port_type WITH =)
    WHERE (user_id IS NOT NULL AND port_range IS NOT NULL)
    """)

    alter table("rules") do
      remove(:user_id_tmp)
    end

    ### oidc_connections refs to users
    rename(table("oidc_connections"), :user_id, to: :user_id_tmp)

    execute(
      "ALTER TABLE oidc_connections RENAME CONSTRAINT oidc_connections_user_id_fkey TO oidc_connections_user_id_tmp_fkey"
    )

    alter table("oidc_connections") do
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all))
    end

    execute(
      "UPDATE oidc_connections SET user_id = (SELECT users.id FROM users WHERE users.id_tmp = oidc_connections.user_id_tmp)"
    )

    execute("ALTER TABLE oidc_connections ALTER COLUMN user_id SET NOT NULL")

    alter table("oidc_connections") do
      remove(:user_id_tmp)
    end

    create(unique_index(:oidc_connections, [:user_id, :provider]))

    ### mfa_methods refs to users
    rename(table("mfa_methods"), :user_id, to: :user_id_tmp)

    execute(
      "ALTER TABLE mfa_methods RENAME CONSTRAINT mfa_methods_user_id_fkey TO mfa_methods_user_id_tmp_fkey"
    )

    alter table("mfa_methods") do
      add(:user_id, references(:users, type: :binary_id, on_delete: :delete_all))
    end

    execute(
      "UPDATE mfa_methods SET user_id = (SELECT users.id FROM users WHERE users.id_tmp = mfa_methods.user_id_tmp)"
    )

    execute("ALTER TABLE mfa_methods ALTER COLUMN user_id SET NOT NULL")

    alter table("mfa_methods") do
      remove(:user_id_tmp)
    end

    create(index(:mfa_methods, [:user_id]))

    alter table("users") do
      remove(:id_tmp)
    end

    execute("ALTER INDEX users_uuid_index RENAME TO users_pkey")

    alter table("users") do
      modify(:id, :binary_id, primary_key: true)
    end
  end
end
