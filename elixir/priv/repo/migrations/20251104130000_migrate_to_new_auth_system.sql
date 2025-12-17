-- Migration: Convert all accounts from legacy auth system to new directory-based system
-- This migration performs the following operations for each account:
-- 0. Delete unsupported legacy auth providers (mock, jumpcloud)
-- 1. Populate actor emails from identities
-- 2. Set allow_email_otp_sign_in based on email identity existence
-- 3. Migrate userpass and email identities (set issuer="firezone")
-- 4. Migrate OpenID Connect identities
-- 5. Migrate Google Workspace identities
-- 6. Migrate Microsoft Entra identities
-- 7. Migrate Okta identities
-- 8. Migrate actor groups to use directory + idp_id instead of provider_id + provider_identifier
-- 9. Create new auth providers for each legacy provider (email, userpass, OIDC, Google, Entra, Okta)
-- 10. Delete legacy auth_providers
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
  -- ============================================================================
  -- STEP 0: DELETE UNSUPPORTED LEGACY AUTH PROVIDERS
  -- ============================================================================
  RAISE NOTICE 'Step 0: Deleting unsupported legacy auth providers (mock, jumpcloud)';

  DELETE FROM legacy_auth_providers
  WHERE adapter IN ('mock', 'jumpcloud');

  -- Loop through each account
  FOR v_account_id IN SELECT id FROM accounts ORDER BY id
  LOOP
    RAISE NOTICE 'Processing account: %', v_account_id;

    -- ============================================================================
    -- STEP 1: POPULATE ACTOR EMAILS
    -- ============================================================================
    RAISE NOTICE 'Step 1: Populating actor emails for account %', v_account_id;

    -- Step 1a: First pass - populate emails from email identities (adapter = 'email')
    -- No duplicate handling needed due to existing provider_id + provider_identifier uniqueness
    UPDATE actors a
    SET email = COALESCE(i.email, i.provider_identifier)
    FROM external_identities i
    JOIN legacy_auth_providers p ON i.provider_id = p.id
    WHERE i.actor_id = a.id
      AND a.account_id = v_account_id
      AND p.account_id = v_account_id
      AND p.adapter = 'email';

    -- Step 1b: Second pass - populate emails from OIDC identities for actors without email
    -- If email is already taken (from Step 1a) or by another OIDC actor, use +firezone-dup-{actor_id} suffix
    -- Priority: actors who haven't signed in (empty provider_state) keep the clean email,
    -- since actors who have signed in can authenticate via issuer/idp_id post-migration
    WITH candidate_emails AS (
      SELECT DISTINCT ON (a.id)
        a.id AS actor_id,
        COALESCE(
          i.email,
          CASE WHEN i.provider_identifier ~ '@' THEN i.provider_identifier ELSE NULL END,
          i.provider_state->'userinfo'->>'email',
          i.provider_state->'claims'->>'email',
          i.provider_state->>'email'
        ) AS candidate_email,
        -- has_signed_in = true if provider_state has claims (user completed OIDC sign-in)
        (i.provider_state IS NOT NULL AND i.provider_state != '{}' AND i.provider_state ? 'claims') AS has_signed_in
      FROM actors a
      JOIN external_identities i ON i.actor_id = a.id
      JOIN legacy_auth_providers p ON i.provider_id = p.id
      WHERE a.account_id = v_account_id
        AND p.account_id = v_account_id
        AND a.email IS NULL
        AND p.adapter IN ('google_workspace', 'okta', 'microsoft_entra', 'openid_connect')
        AND COALESCE(
          i.email,
          CASE WHEN i.provider_identifier ~ '@' THEN i.provider_identifier ELSE NULL END,
          i.provider_state->'userinfo'->>'email',
          i.provider_state->'claims'->>'email',
          i.provider_state->>'email'
        ) IS NOT NULL
      ORDER BY a.id, i.inserted_at DESC
    ),
    ranked_candidates AS (
      SELECT
        c.actor_id,
        c.candidate_email,
        -- Rank: actors who haven't signed in get priority for clean email
        ROW_NUMBER() OVER (
          PARTITION BY LOWER(c.candidate_email)
          ORDER BY
            CASE WHEN c.has_signed_in THEN 1 ELSE 0 END,
            c.actor_id
        ) AS rn,
        -- Check if email was already taken in Step 1a
        EXISTS (
          SELECT 1 FROM actors a2
          WHERE a2.account_id = v_account_id
            AND LOWER(a2.email) = LOWER(c.candidate_email)
        ) AS email_already_taken
      FROM candidate_emails c
    )
    UPDATE actors a
    SET email = CASE
      WHEN r.email_already_taken OR r.rn > 1 THEN
        REGEXP_REPLACE(r.candidate_email, '@', '+firezone-dup-' || a.id || '@')
      ELSE r.candidate_email
    END
    FROM ranked_candidates r
    WHERE a.id = r.actor_id;


    -- ============================================================================
    -- STEP 2: SET allow_email_otp_sign_in BASED ON EMAIL IDENTITIES
    -- (Must run BEFORE deleting email identities in Step 3)
    -- ============================================================================
    RAISE NOTICE 'Step 2: Setting allow_email_otp_sign_in for actors in account %', v_account_id;

    -- Set to true for actors that had email identities, false for all others
    UPDATE actors a
    SET allow_email_otp_sign_in = EXISTS(
      SELECT 1
      FROM external_identities i
      JOIN legacy_auth_providers p ON i.provider_id = p.id
      WHERE i.actor_id = a.id
        AND p.adapter = 'email'
    )
    WHERE a.account_id = v_account_id;

    -- ============================================================================
    -- STEP 3: MIGRATE USERPASS (password_hash) TO ACTORS AND DELETE IDENTITIES
    -- ============================================================================
    RAISE NOTICE 'Step 3: Migrating userpass password_hash to actors for account %', v_account_id;

    -- Step 3a: Move password_hash from userpass identities to actors
    UPDATE actors a
    SET password_hash = (i.provider_state->>'password_hash')
    FROM external_identities i
    JOIN legacy_auth_providers p ON i.provider_id = p.id
    WHERE a.id = i.actor_id
      AND a.account_id = v_account_id
      AND p.account_id = v_account_id
      AND p.adapter = 'userpass'
      AND i.provider_state->>'password_hash' IS NOT NULL;

    -- Step 3b: Delete all userpass identities (password is now on actor)
    DELETE FROM external_identities i
    USING legacy_auth_providers p
    WHERE i.provider_id = p.id
      AND p.account_id = v_account_id
      AND p.adapter = 'userpass';

    -- Step 3c: Delete all email identities (no longer needed)
    DELETE FROM external_identities i
    USING legacy_auth_providers p
    WHERE i.provider_id = p.id
      AND p.account_id = v_account_id
      AND p.adapter = 'email';

    -- ============================================================================
    -- STEP 4: MIGRATE OPENID_CONNECT IDENTITIES
    -- ============================================================================
    RAISE NOTICE 'Step 4: Migrating OpenID Connect identities for account %', v_account_id;

    -- Update all OpenID Connect identities
    UPDATE external_identities i
    SET
      name = a.name,
      idp_id = COALESCE(
        i.provider_identifier,
        i.provider_state->'claims'->>'oid',
        i.provider_state->'claims'->>'sub'
      ),
      issuer = COALESCE(
        i.provider_state->'claims'->>'iss',
        p.adapter_state->'claims'->>'iss',
        REGEXP_REPLACE(
          REGEXP_REPLACE(
            p.adapter_config->>'discovery_document_uri',
            '/\.well-known/.*$',
            ''
          ),
          '/$',
          ''
        )
      )
    FROM actors a, legacy_auth_providers p
    WHERE i.actor_id = a.id
      AND i.provider_id = p.id
      AND p.account_id = v_account_id
      AND p.adapter = 'openid_connect';

    -- ============================================================================
    -- STEP 5: MIGRATE GOOGLE WORKSPACE IDENTITIES
    -- ============================================================================
    RAISE NOTICE 'Step 5: Migrating Google Workspace identities for account %', v_account_id;

    -- Update Google Workspace identities
    UPDATE external_identities i
    SET
      name = a.name,
      idp_id = i.provider_identifier,
      issuer = 'https://accounts.google.com'
    FROM actors a, legacy_auth_providers p
    WHERE i.actor_id = a.id
      AND i.provider_id = p.id
      AND p.account_id = v_account_id
      AND p.adapter = 'google_workspace';

    -- ============================================================================
    -- STEP 6: MIGRATE MICROSOFT ENTRA IDENTITIES
    -- ============================================================================
    RAISE NOTICE 'Step 6: Migrating Microsoft Entra identities for account %', v_account_id;

    -- Update Microsoft Entra identities
    UPDATE external_identities i
    SET
      name = a.name,
      idp_id = COALESCE(
        i.provider_state->'claims'->>'oid',
        i.provider_identifier
      ),
      issuer = COALESCE(
        i.provider_state->'claims'->>'iss',
        p.adapter_state->'claims'->>'iss',
        REGEXP_REPLACE(
          REGEXP_REPLACE(
            p.adapter_config->>'discovery_document_uri',
            '/\.well-known/.*$',
            ''
          ),
          '/$',
          ''
        )
      )
    FROM actors a, legacy_auth_providers p
    WHERE i.actor_id = a.id
      AND i.provider_id = p.id
      AND p.account_id = v_account_id
      AND p.adapter = 'microsoft_entra';

    -- ============================================================================
    -- STEP 7: MIGRATE OKTA IDENTITIES
    -- ============================================================================
    RAISE NOTICE 'Step 7: Migrating Okta identities for account %', v_account_id;

    -- Update Okta identities
    UPDATE external_identities i
    SET
      name = a.name,
      idp_id = i.provider_identifier,
      issuer = COALESCE(
        i.provider_state->'claims'->>'iss',
        p.adapter_state->'claims'->>'iss',
        REGEXP_REPLACE(
          REGEXP_REPLACE(
            p.adapter_config->>'discovery_document_uri',
            '/\.well-known/.*$',
            ''
          ),
          '/$',
          ''
        )
      )
    FROM actors a, legacy_auth_providers p
    WHERE i.actor_id = a.id
      AND i.provider_id = p.id
      AND p.account_id = v_account_id
      AND p.adapter = 'okta';

    -- ============================================================================
    -- STEP 8: MIGRATE ACTOR GROUPS
    -- ============================================================================
    RAISE NOTICE 'Step 8: Migrating actor groups for account %', v_account_id;

    -- Update groups for Google Workspace
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
        ELSE entity_type
      END
    FROM legacy_auth_providers p
    WHERE g.provider_id = p.id
      AND g.account_id = v_account_id
      AND p.adapter = 'google_workspace'
      AND p.adapter_state->'claims'->>'hd' IS NOT NULL;

    -- Update groups for Okta
    -- Strip G: prefix for groups (Okta doesn't have org units)
    UPDATE actor_groups g
    SET
      idp_id = CASE
        WHEN g.provider_identifier LIKE 'G:%' THEN SUBSTRING(g.provider_identifier FROM 3)
        ELSE g.provider_identifier
      END
    FROM legacy_auth_providers p
    WHERE g.provider_id = p.id
      AND g.account_id = v_account_id
      AND p.adapter = 'okta'
      AND p.adapter_state->'claims'->>'iss' IS NOT NULL;

    -- Update groups for Microsoft Entra
    -- Strip G: prefix for groups (Entra doesn't have org units)
    UPDATE actor_groups g
    SET
      idp_id = CASE
        WHEN g.provider_identifier LIKE 'G:%' THEN SUBSTRING(g.provider_identifier FROM 3)
        ELSE g.provider_identifier
      END
    FROM legacy_auth_providers p
    WHERE g.provider_id = p.id
      AND g.account_id = v_account_id
      AND p.adapter = 'microsoft_entra'
      AND p.adapter_state->'claims'->>'tid' IS NOT NULL;

    -- ============================================================================
    -- STEP 9: MIGRATE PROVIDERS (CREATE NEW AUTH PROVIDER RECORDS)
    -- ============================================================================
    RAISE NOTICE 'Step 9: Migrating auth providers for account %', v_account_id;

    -- Step 9a: Migrate Email OTP provider
    INSERT INTO auth_providers (id, account_id, type)
    SELECT p.id, p.account_id, 'email_otp'
    FROM legacy_auth_providers p
    WHERE p.account_id = v_account_id
      AND p.adapter = 'email'
    ON CONFLICT (account_id, id) DO NOTHING;

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

    -- Step 9b: Migrate Userpass provider
    INSERT INTO auth_providers (id, account_id, type)
    SELECT p.id, p.account_id, 'userpass'
    FROM legacy_auth_providers p
    WHERE p.account_id = v_account_id
      AND p.adapter = 'userpass'
    ON CONFLICT (account_id, id) DO NOTHING;

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

    -- Step 9c: Migrate OpenID Connect providers
    INSERT INTO auth_providers (id, account_id, type)
    SELECT p.id, p.account_id, 'oidc'
    FROM legacy_auth_providers p
    WHERE p.account_id = v_account_id
      AND p.adapter = 'openid_connect'
    ON CONFLICT (account_id, id) DO NOTHING;

    INSERT INTO oidc_auth_providers (
      id, account_id, name, issuer, client_id, client_secret,
      discovery_document_uri, is_disabled, is_default, is_legacy, context,
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
            '/\.well-known/.*$',
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
      true,
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
            '/\.well-known/.*$',
            ''
          ),
          '/$',
          ''
        )
      ) IS NOT NULL
    ON CONFLICT (id) DO NOTHING;

    -- Step 9d: Migrate Google Workspace providers as OIDC providers
    INSERT INTO auth_providers (id, account_id, type)
    SELECT p.id, p.account_id, 'oidc'
    FROM legacy_auth_providers p
    WHERE p.account_id = v_account_id
      AND p.adapter = 'google_workspace'
    ON CONFLICT (account_id, id) DO NOTHING;

    INSERT INTO oidc_auth_providers (
      id, account_id, name, issuer, client_id, client_secret,
      discovery_document_uri, is_disabled, is_default, is_legacy, context,
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
      true,
      'clients_and_portal',
      'system',
      NOW(),
      NOW()
    FROM legacy_auth_providers p
    WHERE p.account_id = v_account_id
      AND p.adapter = 'google_workspace'
    ON CONFLICT (id) DO NOTHING;

    -- Step 9d2: Migrate Google Workspace providers with service_account_json_key to google_directories
    -- First, create the parent Directory record
    INSERT INTO directories (account_id, id, type)
    SELECT
      p.account_id,
      gen_random_uuid(),
      'google'
    FROM legacy_auth_providers p
    WHERE p.account_id = v_account_id
      AND p.adapter = 'google_workspace'
      AND p.adapter_config->>'service_account_json_key' IS NOT NULL
    ON CONFLICT DO NOTHING;

    -- Then, create the google_directories record with the same id
    INSERT INTO google_directories (
      id,
      account_id,
      domain,
      name,
      impersonation_email,
      is_verified,
      legacy_service_account_key,
      created_by,
      inserted_at,
      updated_at
    )
    SELECT
      d.id,
      p.account_id,
      COALESCE(p.adapter_state->'claims'->>'hd', ''),
      COALESCE(p.name || ' Directory', 'Google Directory'),
      COALESCE(p.adapter_state->'userinfo'->>'email', ''),
      false,
      (p.adapter_config->>'service_account_json_key')::jsonb,
      'system',
      NOW(),
      NOW()
    FROM legacy_auth_providers p
    JOIN directories d ON d.account_id = p.account_id AND d.type = 'google'
    WHERE p.account_id = v_account_id
      AND p.adapter = 'google_workspace'
      AND p.adapter_config->>'service_account_json_key' IS NOT NULL
    ON CONFLICT (id) DO NOTHING;

    -- Step 9e: Migrate Microsoft Entra providers as OIDC providers
    INSERT INTO auth_providers (id, account_id, type)
    SELECT p.id, p.account_id, 'oidc'
    FROM legacy_auth_providers p
    WHERE p.account_id = v_account_id
      AND p.adapter = 'microsoft_entra'
    ON CONFLICT (account_id, id) DO NOTHING;

    INSERT INTO oidc_auth_providers (
      id, account_id, name, issuer, client_id, client_secret,
      discovery_document_uri, is_disabled, is_default, is_legacy, context,
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
      true,
      'clients_and_portal',
      'system',
      NOW(),
      NOW()
    FROM legacy_auth_providers p
    WHERE p.account_id = v_account_id
      AND p.adapter = 'microsoft_entra'
      AND p.adapter_state->'claims'->>'iss' IS NOT NULL
    ON CONFLICT (id) DO NOTHING;

    -- Step 9f: Migrate Okta providers as OIDC providers
    INSERT INTO auth_providers (id, account_id, type)
    SELECT p.id, p.account_id, 'oidc'
    FROM legacy_auth_providers p
    WHERE p.account_id = v_account_id
      AND p.adapter = 'okta'
    ON CONFLICT (account_id, id) DO NOTHING;

    INSERT INTO oidc_auth_providers (
      id, account_id, name, issuer, client_id, client_secret,
      discovery_document_uri, is_disabled, is_default, is_legacy, context,
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
      true,
      'clients_and_portal',
      'system',
      NOW(),
      NOW()
    FROM legacy_auth_providers p
    WHERE p.account_id = v_account_id
      AND p.adapter = 'okta'
      AND p.adapter_state->'claims'->>'iss' IS NOT NULL
    ON CONFLICT (id) DO NOTHING;

    RAISE NOTICE 'Completed migration for account: %', v_account_id;

  END LOOP;

  RAISE NOTICE 'Migration completed for all accounts';
END $$;
