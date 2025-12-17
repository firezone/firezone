defmodule Portal.Repo.Migrations.BackfillCreatedBySubject do
  use Ecto.Migration

  @tables [
    "actor_groups",
    "auth_identities",
    "auth_providers",
    "gateway_groups",
    "policies",
    "relay_groups",
    "resources",
    "tokens"
  ]

  def up do
    # Backfill tables w/ created_by_subject
    for table <- @tables do
      execute("""
        UPDATE #{table} t
        SET created_by_subject =
          CASE
            WHEN t.created_by = 'system' THEN jsonb_build_object('name', 'System', 'email', NULL)
            WHEN t.created_by = 'provider' THEN jsonb_build_object('name', 'Provider', 'email', NULL)
            ELSE jsonb_build_object(
              'name', COALESCE(data.actor_name, 'Unknown'),
              'email', data.identity_email
            )
          END
        FROM (
          SELECT
            t_inner.id AS tid,
            a.name AS actor_name,
            i.email AS identity_email
          FROM #{table} t_inner
          LEFT JOIN actors a ON t_inner.created_by_actor_id = a.id
          LEFT JOIN auth_identities i ON t_inner.created_by_identity_id = i.id
          WHERE t_inner.created_by_subject IS NULL
        ) AS data
        WHERE t.id = data.tid
      """)
    end

    # Backfill Resource Connections
    execute("""
      UPDATE resource_connections rc
      SET created_by_subject =
        CASE
          WHEN rc.created_by = 'system' THEN jsonb_build_object('name', 'System', 'email', NULL)
          WHEN rc.created_by = 'provider' THEN jsonb_build_object('name', 'Provider', 'email', NULL)
          ELSE jsonb_build_object(
            'name', COALESCE(data.actor_name, 'Unknown'),
            'email', data.identity_email
          )
        END
      FROM (
        SELECT
          rc_inner.resource_id,
          rc_inner.gateway_group_id,
          rc_inner.account_id,
          a.name AS actor_name,
          i.email AS identity_email
        FROM resource_connections rc_inner
        LEFT JOIN actors a ON rc_inner.created_by_actor_id = a.id
        LEFT JOIN auth_identities i ON rc_inner.created_by_identity_id = i.id
        WHERE rc_inner.created_by_subject IS NULL
      ) AS data
      WHERE rc.resource_id = data.resource_id
        AND rc.gateway_group_id = data.gateway_group_id
        AND rc.account_id = data.account_id
    """)

    # Backfill Clients verified_by_subject
    execute("""
      UPDATE clients c
      SET verified_by_subject =
        CASE
          WHEN c.verified_at IS NULL THEN NULL
          WHEN c.verified_by = 'system' THEN jsonb_build_object('name', 'System', 'email', NULL)
          WHEN c.verified_by = 'provider' THEN jsonb_build_object('name', 'Provider', 'email', NULL)
          ELSE jsonb_build_object(
            'name', COALESCE(data.actor_name, 'Unknown'),
            'email', data.identity_email
          )
        END
      FROM (
        SELECT
          c_inner.id AS cid,
          a.name AS actor_name,
          i.email AS identity_email
        FROM clients c_inner
        LEFT JOIN actors a ON c_inner.verified_by_actor_id = a.id
        LEFT JOIN auth_identities i ON c_inner.verified_by_identity_id = i.id
        WHERE c_inner.verified_by_subject IS NULL
      ) AS data
      WHERE c.id = data.cid
    """)
  end

  def down do
    # Remove data from tables w/ created_by_subject
    for table <- @tables do
      execute("""
        UPDATE #{table}
        SET created_by_subject = NULL
      """)
    end

    # Remove created_by_subject data from resource_connections table
    execute("""
      UPDATE resource_connections
      SET created_by_subject = NULL
    """)

    # Remove verified_by_subject data from clients table
    execute("""
      UPDATE clients
      SET verified_by_subject = NULL
    """)
  end
end
