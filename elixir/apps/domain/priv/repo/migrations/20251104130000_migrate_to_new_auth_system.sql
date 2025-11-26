-- Migration: Convert all accounts from legacy auth system to new directory-based system
-- This migration performs the following operations for each account:
-- 1. Populate actor emails from identities
-- 2. Migrate userpass and email identities (set issuer="firezone")
-- 3. Migrate OpenID Connect identities
-- 4. Migrate Google Workspace identities
-- 5. Migrate Microsoft Entra identities
-- 6. Migrate Okta identities
-- 7. Migrate actor groups to use directory + idp_id instead of provider_id + provider_identifier
-- 8. Create new auth providers for each legacy provider (email, userpass, OIDC, Google, Entra, Okta)
-- 9. Delete legacy auth_providers
DO $$
DECLARE
  v_account_id UUID;
  v_actor_id UUID;
  v_identity_id UUID;
  v_provider_id UUID;
  v_group_id UUID;
  v_email TEXT;
  v_issuer TEXT;
  v_idp_id TEXT;
  v_directory UUID;
  v_duplicate_count INT;
BEGIN
  -- Loop through each account
  FOR v_account_id IN SELECT id FROM accounts ORDER BY id
  LOOP
    RAISE NOTICE 'Processing account: %', v_account_id;

    -- ============================================================================
    -- STEP 1: POPULATE ACTOR EMAILS
    -- ============================================================================
    RAISE NOTICE 'Step 1: Populating actor emails for account %', v_account_id;

    -- Step 1a: Handle duplicate identity emails by provider_id and email
    -- Find identities with duplicate emails within the same provider
    WITH duplicate_identities AS (
      SELECT
        i.id AS identity_id,
        i.provider_id,
        i.actor_id,
        a.type AS actor_type,
        a.disabled_at,
        a.inserted_at AS actor_inserted_at,
        COALESCE(
          i.email,
          CASE
            WHEN i.provider_identifier ~ '@' THEN i.provider_identifier
            ELSE (i.provider_state->'userinfo'->>'email')
          END,
          (i.provider_state->'claims'->>'email'),
          (i.provider_state->>'email')
        ) AS extracted_email,
        ROW_NUMBER() OVER (
          PARTITION BY i.provider_id, COALESCE(
            i.email,
            CASE
              WHEN i.provider_identifier ~ '@' THEN i.provider_identifier
              ELSE (i.provider_state->'userinfo'->>'email')
            END,
            (i.provider_state->'claims'->>'email'),
            (i.provider_state->>'email')
          )
          ORDER BY
            CASE WHEN a.type = 'account_admin_user' THEN 0 ELSE 1 END,
            CASE WHEN a.disabled_at IS NULL THEN 0 ELSE 1 END,
            a.inserted_at DESC
        ) AS rn
      FROM external_identities i
      JOIN actors a ON i.actor_id = a.id
      WHERE i.account_id = v_account_id
    ),
    duplicates_to_fix AS (
      SELECT
        identity_id,
        actor_id,
        extracted_email,
        rn
      FROM duplicate_identities
      WHERE extracted_email IS NOT NULL
      GROUP BY provider_id, extracted_email, identity_id, actor_id, rn
      HAVING COUNT(*) > 1 OR rn > 1
    )
    UPDATE actors a
    SET email = CASE
      WHEN d.rn = 1 THEN d.extracted_email
      ELSE REGEXP_REPLACE(d.extracted_email, '@', '+firezone-migrated-' || (d.rn - 1) || '@')
    END
    FROM duplicates_to_fix d
    WHERE a.id = d.actor_id AND a.email IS NULL;

    -- Step 1b: Set actor.email from identity.email where actor.email is null
    UPDATE actors a
    SET email = i.email
    FROM external_identities i
    WHERE a.id = i.actor_id
      AND a.account_id = v_account_id
      AND a.email IS NULL
      AND i.email IS NOT NULL;

    -- Step 1c: Set actor.email from identity.provider_identifier if it contains @
    UPDATE actors a
    SET email = i.provider_identifier
    FROM external_identities i
    WHERE a.id = i.actor_id
      AND a.account_id = v_account_id
      AND a.email IS NULL
      AND i.provider_identifier ~ '@';

    -- Step 1d: Set actor.email from identity.provider_state (various JSON paths)
    UPDATE actors a
    SET email = COALESCE(
      i.provider_state->'userinfo'->>'email',
      i.provider_state->'claims'->>'email',
      i.provider_state->>'email'
    )
    FROM external_identities i
    WHERE a.id = i.actor_id
      AND a.account_id = v_account_id
      AND a.email IS NULL
      AND (
        i.provider_state->'userinfo'->>'email' IS NOT NULL OR
        i.provider_state->'claims'->>'email' IS NOT NULL OR
        i.provider_state->>'email' IS NOT NULL
      );


    -- ============================================================================
    -- STEP 2: MIGRATE USERPASS (password_hash) TO ACTORS AND DELETE IDENTITIES
    -- ============================================================================
    RAISE NOTICE 'Step 2: Migrating userpass password_hash to actors for account %', v_account_id;

    -- Step 2a: Move password_hash from userpass identities to actors
    UPDATE actors a
    SET password_hash = (i.provider_state->>'password_hash')
    FROM external_identities i
    JOIN legacy_auth_providers p ON i.provider_id = p.id
    WHERE a.id = i.actor_id
      AND a.account_id = v_account_id
      AND p.account_id = v_account_id
      AND p.adapter = 'userpass'
      AND i.provider_state->>'password_hash' IS NOT NULL;

    -- Step 2b: Delete all userpass identities (password is now on actor)
    DELETE FROM external_identities i
    USING legacy_auth_providers p
    WHERE i.provider_id = p.id
      AND p.account_id = v_account_id
      AND p.adapter = 'userpass';

    -- Step 2c: Delete all email identities (no longer needed)
    DELETE FROM external_identities i
    USING legacy_auth_providers p
    WHERE i.provider_id = p.id
      AND p.account_id = v_account_id
      AND p.adapter = 'email';

    -- ============================================================================
    -- STEP 3: MIGRATE OPENID_CONNECT IDENTITIES
    -- ============================================================================
    RAISE NOTICE 'Step 3: Migrating OpenID Connect identities for account %', v_account_id;

    -- Delete identities that don't have issuer or idp_id (user never signed in)
    DELETE FROM external_identities i
    USING legacy_auth_providers p
    WHERE i.provider_id = p.id
      AND p.account_id = v_account_id
      AND p.adapter = 'openid_connect'
      AND (
        i.provider_state->'claims'->>'iss' IS NULL OR
        (
          i.provider_state->'claims'->>'oid' IS NULL AND
          i.provider_state->'claims'->>'sub' IS NULL
        )
      );

    -- Update OpenID Connect identities with issuer/idp_id from provider_state
    UPDATE external_identities i
    SET
      name = a.name,
      idp_id = 'oidc:' || COALESCE(
        i.provider_state->'claims'->>'oid',
        i.provider_state->'claims'->>'sub'
      ),
      issuer = i.provider_state->'claims'->>'iss',
      provider_id = NULL
    FROM actors a, legacy_auth_providers p
    WHERE i.actor_id = a.id
      AND i.provider_id = p.id
      AND p.account_id = v_account_id
      AND p.adapter = 'openid_connect'
      AND i.provider_state->'claims'->>'iss' IS NOT NULL
      AND (
        i.provider_state->'claims'->>'oid' IS NOT NULL OR
        i.provider_state->'claims'->>'sub' IS NOT NULL
      );

    -- ============================================================================
    -- STEP 4: MIGRATE GOOGLE WORKSPACE IDENTITIES
    -- ============================================================================
    RAISE NOTICE 'Step 4: Migrating Google Workspace identities for account %', v_account_id;

    -- Update Google Workspace identities
    UPDATE external_identities i
    SET
      name = a.name,
      idp_id = i.provider_identifier,
      issuer = 'https://accounts.google.com',
      provider_id = NULL
    FROM actors a, legacy_auth_providers p
    WHERE i.actor_id = a.id
      AND i.provider_id = p.id
      AND p.account_id = v_account_id
      AND p.adapter = 'google_workspace';

    -- ============================================================================
    -- STEP 5: MIGRATE MICROSOFT ENTRA IDENTITIES
    -- ============================================================================
    RAISE NOTICE 'Step 5: Migrating Microsoft Entra identities for account %', v_account_id;

    -- Update Microsoft Entra identities
    UPDATE external_identities i
    SET
      name = a.name,
      idp_id = COALESCE(
        i.provider_state->'claims'->>'oid',
        i.provider_identifier
      ),
      issuer = p.adapter_state->'claims'->>'iss',
      provider_id = NULL
    FROM actors a, legacy_auth_providers p
    WHERE i.actor_id = a.id
      AND i.provider_id = p.id
      AND p.account_id = v_account_id
      AND p.adapter = 'microsoft_entra'
      AND p.adapter_state->'claims'->>'iss' IS NOT NULL;

    -- ============================================================================
    -- STEP 6: MIGRATE OKTA IDENTITIES
    -- ============================================================================
    RAISE NOTICE 'Step 6: Migrating Okta identities for account %', v_account_id;

    -- Update Okta identities
    UPDATE external_identities i
    SET
      name = a.name,
      idp_id = i.provider_identifier,
      issuer = p.adapter_state->'claims'->>'iss',
      provider_id = NULL
    FROM actors a, legacy_auth_providers p
    WHERE i.actor_id = a.id
      AND i.provider_id = p.id
      AND p.account_id = v_account_id
      AND p.adapter = 'okta'
      AND p.adapter_state->'claims'->>'iss' IS NOT NULL;

    -- ============================================================================
    -- STEP 7: MIGRATE ACTOR GROUPS
    -- ============================================================================
    RAISE NOTICE 'Step 7: Migrating actor groups for account %', v_account_id;

    -- Update groups for Google Workspace
    UPDATE actor_groups g
    SET
      idp_id = g.provider_identifier,
      provider_id = NULL,
      provider_identifier = NULL
    FROM legacy_auth_providers p
    WHERE g.provider_id = p.id
      AND g.account_id = v_account_id
      AND p.adapter = 'google_workspace'
      AND p.adapter_state->'claims'->>'hd' IS NOT NULL;

    -- Update groups for Okta
    UPDATE actor_groups g
    SET
      idp_id = g.provider_identifier,
      provider_id = NULL,
      provider_identifier = NULL
    FROM legacy_auth_providers p
    WHERE g.provider_id = p.id
      AND g.account_id = v_account_id
      AND p.adapter = 'okta'
      AND p.adapter_state->'claims'->>'iss' IS NOT NULL;

    -- Update groups for Microsoft Entra
    -- Handle entity_type and strip prefixes (OU: = org_unit, G: = group)
    UPDATE actor_groups g
    SET
      idp_id = CASE
        WHEN g.provider_identifier LIKE 'OU:%' THEN SUBSTRING(g.provider_identifier FROM 4)
        WHEN g.provider_identifier LIKE 'G:%' THEN SUBSTRING(g.provider_identifier FROM 3)
        ELSE g.provider_identifier
      END,
      entity_type = CASE
        WHEN g.provider_identifier LIKE 'OU:%' THEN 'org_unit'
        WHEN g.provider_identifier LIKE 'G:%' THEN 'group'
        ELSE NULL
      END,
      provider_id = NULL,
      provider_identifier = NULL
    FROM legacy_auth_providers p
    WHERE g.provider_id = p.id
      AND g.account_id = v_account_id
      AND p.adapter = 'microsoft_entra'
      AND p.adapter_state->'claims'->>'tid' IS NOT NULL;

    -- Update groups without provider (clear legacy fields)
    UPDATE actor_groups
    SET
      idp_id = NULL,
      provider_id = NULL,
      provider_identifier = NULL
    WHERE account_id = v_account_id
      AND (provider_id IS NULL OR provider_identifier IS NULL);

    -- ============================================================================
    -- STEP 8: MIGRATE PROVIDERS (CREATE NEW AUTH PROVIDER RECORDS)
    -- ============================================================================
    RAISE NOTICE 'Step 8: Migrating auth providers for account %', v_account_id;

    -- Step 8a: Migrate Email OTP provider
    INSERT INTO auth_providers (id, account_id)
    SELECT p.id, p.account_id
    FROM legacy_auth_providers p
    WHERE p.account_id = v_account_id
      AND p.adapter = 'email'
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO email_otp_auth_providers (id, account_id, name, context, is_disabled, created_by, inserted_at, updated_at)
    SELECT
      p.id,
      p.account_id,
      'Email OTP',
      'clients_and_portal',
      (p.disabled_at IS NOT NULL),
      'system',
      NOW(),
      NOW()
    FROM legacy_auth_providers p
    WHERE p.account_id = v_account_id
      AND p.adapter = 'email'
    ON CONFLICT (id) DO NOTHING;

    -- Step 8b: Migrate Userpass provider
    INSERT INTO auth_providers (id, account_id)
    SELECT p.id, p.account_id
    FROM legacy_auth_providers p
    WHERE p.account_id = v_account_id
      AND p.adapter = 'userpass'
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO userpass_auth_providers (id, account_id, name, context, is_disabled, created_by, inserted_at, updated_at)
    SELECT
      p.id,
      p.account_id,
      'Username & Password',
      'clients_and_portal',
      (p.disabled_at IS NOT NULL),
      'system',
      NOW(),
      NOW()
    FROM legacy_auth_providers p
    WHERE p.account_id = v_account_id
      AND p.adapter = 'userpass'
    ON CONFLICT (id) DO NOTHING;

    -- Step 8c: Migrate OpenID Connect providers
    INSERT INTO auth_providers (id, account_id)
    SELECT p.id, p.account_id
    FROM legacy_auth_providers p
    WHERE p.account_id = v_account_id
      AND p.adapter = 'openid_connect'
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO oidc_auth_providers (
      id, account_id, name, issuer, client_id, client_secret,
      discovery_document_uri, is_disabled, is_default, context,
      created_by, inserted_at, updated_at
    )
    SELECT
      p.id,
      p.account_id,
      p.name,
      COALESCE(
        p.adapter_state->'claims'->>'iss',
        (
          SELECT i.provider_state->'claims'->>'iss'
          FROM external_identities i
          WHERE i.provider_id = p.id
            AND i.provider_state->'claims'->>'iss' IS NOT NULL
          LIMIT 1
        ),
        REGEXP_REPLACE(
          REGEXP_REPLACE(
            p.adapter_config->>'discovery_document_uri',
            '/\\.well-known/.*$',
            ''
          ),
          '/$',
          ''
        )
      ),
      p.adapter_config->>'client_id',
      p.adapter_config->>'client_secret',
      p.adapter_config->>'discovery_document_uri',
      (p.disabled_at IS NOT NULL),
      (p.assigned_default_at IS NOT NULL),
      'clients_and_portal',
      'system',
      NOW(),
      NOW()
    FROM legacy_auth_providers p
    WHERE p.account_id = v_account_id
      AND p.adapter = 'openid_connect'
      AND COALESCE(
        p.adapter_state->'claims'->>'iss',
        (
          SELECT i.provider_state->'claims'->>'iss'
          FROM external_identities i
          WHERE i.provider_id = p.id
            AND i.provider_state->'claims'->>'iss' IS NOT NULL
          LIMIT 1
        ),
        REGEXP_REPLACE(
          REGEXP_REPLACE(
            p.adapter_config->>'discovery_document_uri',
            '/\\.well-known/.*$',
            ''
          ),
          '/$',
          ''
        )
      ) IS NOT NULL
    ON CONFLICT (id) DO NOTHING;

    -- Step 8d: Migrate Google Workspace providers as OIDC providers
    INSERT INTO auth_providers (id, account_id)
    SELECT p.id, p.account_id
    FROM legacy_auth_providers p
    WHERE p.account_id = v_account_id
      AND p.adapter = 'google_workspace'
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO oidc_auth_providers (
      id, account_id, name, issuer, client_id, client_secret,
      discovery_document_uri, is_disabled, is_default, context,
      created_by, inserted_at, updated_at
    )
    SELECT
      p.id,
      p.account_id,
      p.name,
      'https://accounts.google.com',
      p.adapter_config->>'client_id',
      p.adapter_config->>'client_secret',
      'https://accounts.google.com/.well-known/openid-configuration',
      (p.disabled_at IS NOT NULL),
      (p.assigned_default_at IS NOT NULL),
      'clients_and_portal',
      'system',
      NOW(),
      NOW()
    FROM legacy_auth_providers p
    WHERE p.account_id = v_account_id
      AND p.adapter = 'google_workspace'
    ON CONFLICT (id) DO NOTHING;

    -- Step 8e: Migrate Microsoft Entra providers as OIDC providers
    INSERT INTO auth_providers (id, account_id)
    SELECT p.id, p.account_id
    FROM legacy_auth_providers p
    WHERE p.account_id = v_account_id
      AND p.adapter = 'microsoft_entra'
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO oidc_auth_providers (
      id, account_id, name, issuer, client_id, client_secret,
      discovery_document_uri, is_disabled, is_default, context,
      created_by, inserted_at, updated_at
    )
    SELECT
      p.id,
      p.account_id,
      p.name,
      p.adapter_state->'claims'->>'iss',
      p.adapter_config->>'client_id',
      p.adapter_config->>'client_secret',
      p.adapter_config->>'discovery_document_uri',
      (p.disabled_at IS NOT NULL),
      (p.assigned_default_at IS NOT NULL),
      'clients_and_portal',
      'system',
      NOW(),
      NOW()
    FROM legacy_auth_providers p
    WHERE p.account_id = v_account_id
      AND p.adapter = 'microsoft_entra'
      AND p.adapter_state->'claims'->>'iss' IS NOT NULL
    ON CONFLICT (id) DO NOTHING;

    -- Step 8f: Migrate Okta providers as OIDC providers
    INSERT INTO auth_providers (id, account_id)
    SELECT p.id, p.account_id
    FROM legacy_auth_providers p
    WHERE p.account_id = v_account_id
      AND p.adapter = 'okta'
    ON CONFLICT (id) DO NOTHING;

    INSERT INTO oidc_auth_providers (
      id, account_id, name, issuer, client_id, client_secret,
      discovery_document_uri, is_disabled, is_default, context,
      created_by, inserted_at, updated_at
    )
    SELECT
      p.id,
      p.account_id,
      p.name,
      p.adapter_state->'claims'->>'iss',
      p.adapter_config->>'client_id',
      p.adapter_config->>'client_secret',
      p.adapter_config->>'discovery_document_uri',
      (p.disabled_at IS NOT NULL),
      (p.assigned_default_at IS NOT NULL),
      'clients_and_portal',
      'system',
      NOW(),
      NOW()
    FROM legacy_auth_providers p
    WHERE p.account_id = v_account_id
      AND p.adapter = 'okta'
      AND p.adapter_state->'claims'->>'iss' IS NOT NULL
    ON CONFLICT (id) DO NOTHING;

    -- ============================================================================
    -- STEP 9: DELETE LEGACY PROVIDERS
    -- ============================================================================
    RAISE NOTICE 'Step 9: Deleting legacy auth providers for account %', v_account_id;

    DELETE FROM legacy_auth_providers
    WHERE account_id = v_account_id;

    RAISE NOTICE 'Completed migration for account: %', v_account_id;

  END LOOP;

  RAISE NOTICE 'Migration completed for all accounts';
END $$;
