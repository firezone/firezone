defmodule Portal.Repo.Migrations.DedupExternalIdentitiesByActorIssuer do
  use Ecto.Migration

  @disable_ddl_transaction true

  # Resolves duplicate external identities so that every (account_id, actor_id,
  # issuer) holds at most one row, in preparation for a unique index on that
  # tuple. directory_id has no bearing here.
  #
  # Duplicates arose because the value stored in idp_id for the same person
  # changed over time (email -> provider subject, Entra sub -> oid, etc.) while
  # the upsert keyed conflicts on idp_id, so each change inserted a fresh row
  # instead of updating in place.
  #
  # Two phases:
  #
  #   1. Same email: collapse rows that share (account_id, actor_id, issuer,
  #      email), keeping the most recently used row (greatest updated_at, then
  #      inserted_at). This folds together the same person's stale idp_id rows.
  #
  #   2. Different emails on one actor: these are different people merged onto
  #      one actor. The row whose email matches the actor's own email stays; each
  #      other email is relocated to the actor that owns that email (reused if it
  #      already exists, created otherwise). If the target actor already has an
  #      identity for this issuer the relocated row is redundant and is deleted.
  #      A row with no email cannot own an account_user actor, so it is deleted.
  #
  #      Relocating only flips actor_id; group memberships and live sessions for
  #      the relocated person are left for the next directory sign-in/sync to
  #      reconcile rather than rebuilt here.
  def up do
    execute("""
    CREATE PROCEDURE pg_temp.collapse_same_email_identities()
    LANGUAGE plpgsql
    AS $$
    DECLARE
      v_deleted integer;
    BEGIN
      LOOP
        WITH ranked AS (
          SELECT
            ei.id,
            ei.account_id,
            ROW_NUMBER() OVER (
              PARTITION BY ei.account_id, ei.actor_id, ei.issuer, ei.email
              ORDER BY ei.updated_at DESC NULLS LAST, ei.inserted_at DESC, ei.id DESC
            ) AS rn
          FROM external_identities ei
        ),
        doomed AS (
          SELECT id, account_id FROM ranked WHERE rn > 1 LIMIT 5000
        )
        DELETE FROM external_identities ei
        USING doomed d
        WHERE ei.account_id = d.account_id
          AND ei.id = d.id;

        GET DIAGNOSTICS v_deleted = ROW_COUNT;
        EXIT WHEN v_deleted = 0;
        COMMIT;
      END LOOP;
    END;
    $$;
    """)

    execute("CALL pg_temp.collapse_same_email_identities()")

    execute("""
    CREATE PROCEDURE pg_temp.split_mixed_email_identities()
    LANGUAGE plpgsql
    AS $$
    DECLARE
      g RECORD;
      r RECORD;
      v_actor_email citext;
      v_actor_disabled_at timestamptz;
      v_home_id uuid;
      v_target_actor uuid;
      v_new_actor uuid;
    BEGIN
      FOR g IN
        SELECT account_id, actor_id, issuer
        FROM external_identities
        GROUP BY account_id, actor_id, issuer
        HAVING COUNT(*) > 1
      LOOP
        SELECT email, disabled_at INTO v_actor_email, v_actor_disabled_at
        FROM actors
        WHERE account_id = g.account_id AND id = g.actor_id;

        -- Home row: the one matching the actor's own email, else the newest.
        SELECT id INTO v_home_id
        FROM external_identities
        WHERE account_id = g.account_id AND actor_id = g.actor_id AND issuer = g.issuer
          AND v_actor_email IS NOT NULL AND email = v_actor_email
        ORDER BY updated_at DESC NULLS LAST, inserted_at DESC, id DESC
        LIMIT 1;

        IF v_home_id IS NULL THEN
          SELECT id INTO v_home_id
          FROM external_identities
          WHERE account_id = g.account_id AND actor_id = g.actor_id AND issuer = g.issuer
          ORDER BY updated_at DESC NULLS LAST, inserted_at DESC, id DESC
          LIMIT 1;
        END IF;

        FOR r IN
          SELECT id, email, name, directory_id
          FROM external_identities
          WHERE account_id = g.account_id AND actor_id = g.actor_id AND issuer = g.issuer
            AND id <> v_home_id
        LOOP
          IF r.email IS NULL THEN
            DELETE FROM external_identities
            WHERE account_id = g.account_id AND id = r.id;
            CONTINUE;
          END IF;

          SELECT id INTO v_target_actor
          FROM actors
          WHERE account_id = g.account_id AND email = r.email AND id <> g.actor_id
          LIMIT 1;

          IF v_target_actor IS NULL THEN
            v_new_actor := gen_random_uuid();

            -- Carry over the merged actor's disabled_at so a relocated person is
            -- not silently re-enabled, and created_by_directory_id from the
            -- relocated identity so provider cleanup can later reap the actor if
            -- the IdP user is removed. name is bounded to the actors.name 255
            -- limit. Group memberships are left for the next directory sync to
            -- reconcile rather than copied here.
            INSERT INTO actors (id, type, account_id, email, name, created_by_directory_id, disabled_at, inserted_at, updated_at)
            VALUES (
              v_new_actor,
              'account_user',
              g.account_id,
              r.email,
              LEFT(COALESCE(NULLIF(r.name, ''), r.email::text), 255),
              r.directory_id,
              v_actor_disabled_at,
              now(),
              now()
            );

            UPDATE external_identities
            SET actor_id = v_new_actor
            WHERE account_id = g.account_id AND id = r.id;
          ELSIF EXISTS (
            SELECT 1 FROM external_identities
            WHERE account_id = g.account_id AND actor_id = v_target_actor AND issuer = g.issuer
          ) THEN
            DELETE FROM external_identities
            WHERE account_id = g.account_id AND id = r.id;
          ELSE
            UPDATE external_identities
            SET actor_id = v_target_actor
            WHERE account_id = g.account_id AND id = r.id;
          END IF;
        END LOOP;

        COMMIT;
      END LOOP;
    END;
    $$;
    """)

    execute("CALL pg_temp.split_mixed_email_identities()")
  end

  def down do
    :ok
  end
end
