defmodule Domain.Migrator do
  @moduledoc """
    This module handles migrating from the old auth system to the new
    directory-based system. This module can be removed once all customers
    have completed the migration.
  """

  import Ecto.Query

  alias Domain.{
    Auth,
    Accounts,
    AuthProviders,
    EmailOTP,
    Userpass,
    PubSub,
    Repo,
    Safe
  }

  def legacy_google_providers(%Accounts.Account{} = account) do
    from(ap in Auth.Provider,
      where: ap.account_id == ^account.id and ap.adapter == :google_workspace
    )
    |> Repo.all()
  end

  def legacy_entra_providers(%Accounts.Account{} = account) do
    from(ap in Auth.Provider,
      where: ap.account_id == ^account.id and ap.adapter == :microsoft_entra
    )
    |> Repo.all()
  end

  def legacy_okta_providers(%Accounts.Account{} = account) do
    from(ap in Auth.Provider, where: ap.account_id == ^account.id and ap.adapter == :okta)
    |> Repo.all()
  end

  def legacy_oidc_providers(%Accounts.Account{} = account) do
    from(ap in Auth.Provider,
      where: ap.account_id == ^account.id and ap.adapter == :openid_connect
    )
    |> Repo.all()
  end

  def legacy_userpass_provider(%Accounts.Account{} = account) do
    from(ap in Auth.Provider, where: ap.account_id == ^account.id and ap.adapter == :userpass)
    |> Repo.one()
  end

  def legacy_email_otp_provider(%Accounts.Account{} = account) do
    from(ap in Auth.Provider, where: ap.account_id == ^account.id and ap.adapter == :email)
    |> Repo.one()
  end

  def start_migration_monitoring(id) do
    :ok = PubSub.subscribe("migration_monitoring:#{id}")
  end

  def up(%Auth.Subject{} = subject) do
    require Logger

    Repo.transact(fn ->
      # Step 1: Populate actor emails
      Logger.info("Starting migration: populate_actor_emails")
      email_errors = populate_actor_emails(subject)

      # Step 2: Migrate userpass and email identities first (these set issuer="firezone")
      Logger.info("Starting migration: populate_identity_idp_fields (userpass + email)")
      identity_errors = populate_identity_idp_fields(subject)

      # Step 3: Migrate all other identity types
      Logger.info("Starting migration: migrate_openid_connect_identities")
      oidc_errors = migrate_openid_connect_identities(subject)

      Logger.info("Starting migration: migrate_google_workspace_identities")
      google_errors = migrate_google_workspace_identities(subject)

      Logger.info("Starting migration: migrate_microsoft_entra_identities")
      entra_errors = migrate_microsoft_entra_identities(subject)

      Logger.info("Starting migration: migrate_okta_identities")
      okta_errors = migrate_okta_identities(subject)

      # Step 4: Migrate actor groups
      Logger.info("Starting migration: migrate_actor_groups")
      group_errors = migrate_actor_groups(subject)

      # Step 5: Migrate providers
      Logger.info("Starting migration: migrate_email_provider")
      migrate_email_provider(subject)

      Logger.info("Starting migration: migrate_userpass_provider")
      migrate_userpass_provider(subject)

      Logger.info("Starting migration: migrate_oidc_providers")
      oidc_provider_errors = migrate_oidc_providers(subject)

      Logger.info("Starting migration: migrate_google_providers")
      google_provider_errors = migrate_google_providers(subject)

      Logger.info("Starting migration: migrate_entra_providers")
      entra_provider_errors = migrate_entra_providers(subject)

      Logger.info("Starting migration: migrate_okta_providers")
      okta_provider_errors = migrate_okta_providers(subject)

      # Step 6: Clean up legacy providers
      Logger.info("Starting migration: delete_legacy_providers")
      delete_legacy_providers(subject)

      Logger.info("Migration completed successfully")

      {:ok,
       %{
         email_errors: email_errors,
         identity_errors: identity_errors,
         oidc_errors: oidc_errors,
         google_errors: google_errors,
         entra_errors: entra_errors,
         okta_errors: okta_errors,
         group_errors: group_errors,
         oidc_provider_errors: oidc_provider_errors,
         google_provider_errors: google_provider_errors,
         entra_provider_errors: entra_provider_errors,
         okta_provider_errors: okta_provider_errors
       }}
    end)

    # 0. Populate actors with email from one of auth_identities
    # 1. Create an email/otp auth provider
    # 2. Set enabled on email/otp auth if was enabled
    #      Update all existing auth_identities with issuer = "<email_auth_provider_id>" and "subject" = email
    #      Update all relevant policy conditions to point to the new auth_provider_id
    # 3. If userpass auth was enabled, create a userpass_auth_provider
    #    Update all auth_identities with issuer = "<userpass_auth_provider_id>" and "subject" = username (email)
    #    Update all policy conditions to point to the new auth_provider_id
    #    If was default, make this the new default
    # 4. Create a corresponding oidc_auth_provider for all existing generic oidc auth providers
    #    If was enabled, set enabled
    #    Look in auth_identities, if iss and sub exist, copy this to issuer and subject. If not, delete the auth_identity
    #    Update all policy conditions to point to the new auth_provider_id
    #    If was default, make this the new default
    # 5. For all google workspace legacy_auth_providers that are not disabled or deleted, and have adapter_state->'claims'->>'hd'
    #    Create google_auth_provider
    #    Create google_directory
    #    Update all policy conditions to point to the new auth_provider_id
    #    If was default, make this the new default
    #    For all auth_identities with iss and sub, copy this to issuer and subject. If not, delete the auth_identity
    #    For all actor_groups associated to this provider, copy issuer and provider_identifier minus G: and OU: prefixes off subject
    # 6. For all microsoft_entra legacy_auth_providers that are not disabled or deleted, and have adapter_state->'claims'->>'tid'
    #    Create entra_auth_provider and entra_directory
    #    Update all policy conditions to point to the new auth_provider_id
    #    If was default, make this the new default
    #    For all auth_identities with iss and sub, copy this to issuer and subject. If not, delete the auth_identity
    #    For all actor_groups associated to this provider, copy issuer and provider_identifier minus G: and OU: prefixes off subject
    # 7. For all okta legacy_auth_providers that are not disabled or deleted, and have adapter_state->'claims'->>'iss'
    #    Create oidc_auth_provider (not okta-specific since we don't have all required Okta fields)
    #    Update all policy conditions to point to the new auth_provider_id
    #    If was default, make this the new default
    #    For all auth_identities with iss and sub, copy this to issuer and subject. If not, delete the auth_identity
    #    For all actor_groups associated to this provider, copy issuer and provider_identifier minus G: and OU: prefixes off subject
    # 8. Update all auth_providers to disabled, disable sync, update all provider_id to NULL on auth_identities and actor_groups in account
    # 9. Show summary / done
  end

  defp populate_actor_emails(%Auth.Subject{} = subject) do
    errors = []

    # Step 1 & 2: Handle duplicates by provider_id and email
    errors = errors ++ handle_duplicate_identity_emails(subject.account)

    # Step 3: Set actor.email from identity.email where actor.email is null
    errors = errors ++ populate_actor_emails_from_identities(subject.account)

    # Step 4: Set service account emails
    errors = errors ++ populate_service_account_emails(subject.account)

    # Step 5: Set api client emails
    errors = errors ++ populate_api_client_emails(subject.account)

    errors
  end

  defp populate_identity_idp_fields(%Auth.Subject{} = subject) do
    issuer = "firezone"

    # Get userpass provider first
    userpass_providers =
      from(p in Auth.Provider,
        where: p.account_id == ^subject.account.id and p.adapter == :userpass,
        select: %{id: p.id, adapter: p.adapter}
      )
      |> Repo.all()

    # Get email provider
    email_providers =
      from(p in Auth.Provider,
        where: p.account_id == ^subject.account.id and p.adapter == :email,
        select: %{id: p.id, adapter: p.adapter}
      )
      |> Repo.all()

    # Process userpass providers first
    userpass_errors =
      Enum.flat_map(userpass_providers, fn provider ->
        # Get all identities for this provider with their actors
        identities =
          from(i in Auth.Identity,
            where: i.provider_id == ^provider.id,
            join: a in Domain.Actors.Actor,
            on: i.actor_id == a.id,
            select: %{
              identity_id: i.id,
              actor_name: a.name,
              provider_identifier: i.provider_identifier,
              provider_state: i.provider_state,
              inserted_at: i.inserted_at
            }
          )
          |> Repo.all()

        # Group identities by provider_identifier to find duplicates
        grouped = Enum.group_by(identities, & &1.provider_identifier)

        # For each group, keep the oldest identity and delete the rest
        delete_errors =
          Enum.flat_map(grouped, fn {_provider_identifier, group_identities} ->
            if length(group_identities) > 1 do
              # Sort by inserted_at and keep the first (oldest)
              [_keep | to_delete] = Enum.sort_by(group_identities, & &1.inserted_at)

              # Delete the duplicates
              Enum.flat_map(to_delete, fn identity ->
                try do
                  from(i in Auth.Identity, where: i.id == ^identity.identity_id)
                  |> Repo.delete_all()

                  []
                rescue
                  e ->
                    [
                      %{
                        identity_id: identity.identity_id,
                        actor_name: identity.actor_name,
                        provider_identifier: identity.provider_identifier,
                        error: "Failed to delete duplicate: #{Exception.message(e)}"
                      }
                    ]
                end
              end)
            else
              []
            end
          end)

        # Now update the remaining userpass identities with password_hash
        update_errors =
          Enum.flat_map(grouped, fn {_provider_identifier, group_identities} ->
            # Get the identity to keep (oldest one)
            identity = Enum.min_by(group_identities, & &1.inserted_at)

            # Extract password_hash from provider_state
            password_hash = get_in(identity.provider_state, ["password_hash"])

            # Update with password_hash and clear provider_state
            case Repo.update_all(
                   from(i in Auth.Identity, where: i.id == ^identity.identity_id),
                   set: [
                     name: identity.actor_name,
                     idp_id: identity.provider_identifier,
                     issuer: issuer,
                     password_hash: password_hash,
                     provider_id: nil,
                     provider_state: %{}
                   ]
                 ) do
              {1, _} ->
                []

              {0, _} ->
                [
                  %{
                    identity_id: identity.identity_id,
                    actor_name: identity.actor_name,
                    provider_identifier: identity.provider_identifier,
                    error: "Identity not found"
                  }
                ]

              other ->
                [
                  %{
                    identity_id: identity.identity_id,
                    actor_name: identity.actor_name,
                    provider_identifier: identity.provider_identifier,
                    error: "Unexpected update result: #{inspect(other)}"
                  }
                ]
            end
          end)

        delete_errors ++ update_errors
      end)

    # Process email providers - skip if userpass identity already exists
    email_errors =
      Enum.flat_map(email_providers, fn provider ->
        # Get all identities for this provider with their actors
        identities =
          from(i in Auth.Identity,
            where: i.provider_id == ^provider.id,
            join: a in Domain.Actors.Actor,
            on: i.actor_id == a.id,
            select: %{
              identity_id: i.id,
              actor_name: a.name,
              provider_identifier: i.provider_identifier,
              inserted_at: i.inserted_at
            }
          )
          |> Repo.all()

        # Group identities by provider_identifier to find duplicates
        grouped = Enum.group_by(identities, & &1.provider_identifier)

        # For each group, keep the oldest identity and delete the rest
        delete_errors =
          Enum.flat_map(grouped, fn {_provider_identifier, group_identities} ->
            if length(group_identities) > 1 do
              # Sort by inserted_at and keep the first (oldest)
              [_keep | to_delete] = Enum.sort_by(group_identities, & &1.inserted_at)

              # Delete the duplicates
              Enum.flat_map(to_delete, fn identity ->
                try do
                  from(i in Auth.Identity, where: i.id == ^identity.identity_id)
                  |> Repo.delete_all()

                  []
                rescue
                  e ->
                    [
                      %{
                        identity_id: identity.identity_id,
                        actor_name: identity.actor_name,
                        provider_identifier: identity.provider_identifier,
                        error: "Failed to delete duplicate: #{Exception.message(e)}"
                      }
                    ]
                end
              end)
            else
              []
            end
          end)

        # Now check each email identity - skip if userpass identity with same (issuer, idp_id) exists
        update_errors =
          Enum.flat_map(grouped, fn {_provider_identifier, group_identities} ->
            # Get the identity to keep (oldest one)
            identity = Enum.min_by(group_identities, & &1.inserted_at)

            # Check if a userpass identity with this (account_id, issuer, idp_id) already exists
            existing =
              from(i in Auth.Identity,
                where:
                  i.account_id == ^subject.account.id and i.issuer == ^issuer and
                    i.idp_id == ^identity.provider_identifier and i.id != ^identity.identity_id
              )
              |> Repo.one()

            if existing do
              # Delete this email identity - userpass identity already exists
              from(i in Auth.Identity, where: i.id == ^identity.identity_id)
              |> Repo.delete_all()

              [
                %{
                  identity_id: identity.identity_id,
                  actor_name: identity.actor_name,
                  provider_identifier: identity.provider_identifier,
                  error:
                    "Deleted email identity - userpass identity with same issuer/idp_id already exists"
                }
              ]
            else
              # Safe to update - clear provider_state for email identities
              case Repo.update_all(
                     from(i in Auth.Identity, where: i.id == ^identity.identity_id),
                     set: [
                       name: identity.actor_name,
                       idp_id: identity.provider_identifier,
                       issuer: issuer,
                       provider_id: nil,
                       provider_state: %{}
                     ]
                   ) do
                {1, _} ->
                  []

                {0, _} ->
                  [
                    %{
                      identity_id: identity.identity_id,
                      actor_name: identity.actor_name,
                      provider_identifier: identity.provider_identifier,
                      error: "Identity not found"
                    }
                  ]

                other ->
                  [
                    %{
                      identity_id: identity.identity_id,
                      actor_name: identity.actor_name,
                      provider_identifier: identity.provider_identifier,
                      error: "Unexpected update result: #{inspect(other)}"
                    }
                  ]
              end
            end
          end)

        delete_errors ++ update_errors
      end)

    userpass_errors ++ email_errors
  end

  defp migrate_openid_connect_identities(%Auth.Subject{} = subject) do
    # Get all legacy openid_connect providers for the account
    legacy_providers =
      from(p in Auth.Provider,
        where: p.account_id == ^subject.account.id and p.adapter == :openid_connect,
        select: %{id: p.id}
      )
      |> Repo.all()

    # Process each legacy provider
    Enum.flat_map(legacy_providers, fn provider ->
      # Get all identities for this provider with their actors
      identities =
        from(i in Auth.Identity,
          where: i.provider_id == ^provider.id,
          join: a in Domain.Actors.Actor,
          on: i.actor_id == a.id,
          select: %{
            identity_id: i.id,
            actor_name: a.name,
            provider_state: i.provider_state,
            provider_identifier: i.provider_identifier
          }
        )
        |> Repo.all()

      # Process each identity
      Enum.flat_map(identities, fn identity ->
        # Extract issuer and idp_id from provider_state
        # For OIDC, prefer "oid" claim (used by Entra), fall back to "sub"
        {issuer, idp_id} = extract_oidc_claims(identity.provider_state)

        cond do
          # If issuer or idp_id is missing, delete the identity (user never signed in)
          is_nil(issuer) or is_nil(idp_id) ->
            try do
              from(i in Auth.Identity, where: i.id == ^identity.identity_id)
              |> Repo.delete_all()

              []
            rescue
              e ->
                [
                  %{
                    identity_id: identity.identity_id,
                    actor_name: identity.actor_name,
                    error: "Failed to delete: #{Exception.message(e)}"
                  }
                ]
            end

          # Otherwise, update the identity with the new fields
          true ->
            try do
              case Repo.update_all(
                     from(i in Auth.Identity, where: i.id == ^identity.identity_id),
                     set: [
                       name: identity.actor_name,
                       idp_id: idp_id,
                       issuer: issuer,
                       provider_id: nil
                     ]
                   ) do
                {1, _} ->
                  []

                {0, _} ->
                  [
                    %{
                      identity_id: identity.identity_id,
                      actor_name: identity.actor_name,
                      issuer: issuer,
                      idp_id: idp_id,
                      error: "Identity not found"
                    }
                  ]
              end
            rescue
              e in Postgrex.Error ->
                [
                  %{
                    identity_id: identity.identity_id,
                    actor_name: identity.actor_name,
                    issuer: issuer,
                    idp_id: idp_id,
                    error: "Constraint violation (skipped): #{Exception.message(e)}"
                  }
                ]
            end
        end
      end)
    end)
  end

  defp extract_oidc_claims(provider_state) when is_map(provider_state) do
    issuer = get_in(provider_state, ["claims", "iss"])
    # Prefer "oid" claim (Microsoft Entra), fall back to "sub"
    idp_id =
      get_in(provider_state, ["claims", "oid"]) || get_in(provider_state, ["claims", "sub"])

    {issuer, idp_id}
  end

  defp extract_oidc_claims(_), do: {nil, nil}

  defp migrate_google_workspace_identities(%Auth.Subject{} = subject) do
    # Get all legacy google_workspace providers for the account
    legacy_providers =
      from(p in Auth.Provider,
        where: p.account_id == ^subject.account.id and p.adapter == :google_workspace,
        select: %{id: p.id, adapter_state: p.adapter_state}
      )
      |> Repo.all()

    # Process each legacy provider
    Enum.flat_map(legacy_providers, fn provider ->
      # Get all identities for this provider with their actors
      identities =
        from(i in Auth.Identity,
          where: i.provider_id == ^provider.id,
          join: a in Domain.Actors.Actor,
          on: i.actor_id == a.id,
          select: %{
            identity_id: i.id,
            actor_name: a.name,
            provider_identifier: i.provider_identifier
          }
        )
        |> Repo.all()

      # Process each identity
      Enum.flat_map(identities, fn identity ->
        try do
          case Repo.update_all(
                 from(i in Auth.Identity, where: i.id == ^identity.identity_id),
                 set: [
                   name: identity.actor_name,
                   idp_id: identity.provider_identifier,
                   issuer: "https://accounts.google.com",
                   provider_id: nil
                 ]
               ) do
            {1, _} ->
              []

            {0, _} ->
              [
                %{
                  identity_id: identity.identity_id,
                  actor_name: identity.actor_name,
                  provider_identifier: identity.provider_identifier,
                  error: "Identity not found"
                }
              ]
          end
        rescue
          e in Postgrex.Error ->
            [
              %{
                identity_id: identity.identity_id,
                actor_name: identity.actor_name,
                provider_identifier: identity.provider_identifier,
                error: "Constraint violation (skipped): #{Exception.message(e)}"
              }
            ]
        end
      end)
    end)
  end

  defp migrate_microsoft_entra_identities(%Auth.Subject{} = subject) do
    # Get all legacy microsoft_entra providers for the account
    legacy_providers =
      from(p in Auth.Provider,
        where: p.account_id == ^subject.account.id and p.adapter == :microsoft_entra,
        select: %{id: p.id, adapter_state: p.adapter_state}
      )
      |> Repo.all()

    # Process each legacy provider
    Enum.flat_map(legacy_providers, fn provider ->
      # Extract the issuer and tenant ID from the provider's adapter_state
      issuer = get_in(provider.adapter_state, ["claims", "iss"])

      # Get all identities for this provider with their actors
      identities =
        from(i in Auth.Identity,
          where: i.provider_id == ^provider.id,
          join: a in Domain.Actors.Actor,
          on: i.actor_id == a.id,
          select: %{
            identity_id: i.id,
            actor_name: a.name,
            provider_identifier: i.provider_identifier,
            provider_state: i.provider_state
          }
        )
        |> Repo.all()

      # Process each identity
      Enum.flat_map(identities, fn identity ->
        # For Entra, prefer "oid" claim if available, otherwise fall back to provider_identifier
        idp_id =
          get_in(identity.provider_state, ["claims", "oid"]) || identity.provider_identifier

        try do
          case Repo.update_all(
                 from(i in Auth.Identity, where: i.id == ^identity.identity_id),
                 set: [
                   name: identity.actor_name,
                   idp_id: idp_id,
                   issuer: issuer,
                   provider_id: nil
                 ]
               ) do
            {1, _} ->
              []

            {0, _} ->
              [
                %{
                  identity_id: identity.identity_id,
                  actor_name: identity.actor_name,
                  provider_identifier: identity.provider_identifier,
                  issuer: issuer,
                  error: "Identity not found"
                }
              ]
          end
        rescue
          e in Postgrex.Error ->
            [
              %{
                identity_id: identity.identity_id,
                actor_name: identity.actor_name,
                provider_identifier: identity.provider_identifier,
                issuer: issuer,
                error: "Constraint violation (skipped): #{Exception.message(e)}"
              }
            ]
        end
      end)
    end)
  end

  defp migrate_okta_identities(%Auth.Subject{} = subject) do
    # Get all legacy okta providers for the account
    legacy_providers =
      from(p in Auth.Provider,
        where: p.account_id == ^subject.account.id and p.adapter == :okta,
        select: %{id: p.id, adapter_state: p.adapter_state}
      )
      |> Repo.all()

    # Process each legacy provider
    Enum.flat_map(legacy_providers, fn provider ->
      # Extract the issuer from the provider's adapter_state
      issuer = get_in(provider.adapter_state, ["claims", "iss"])

      # Get all identities for this provider with their actors
      identities =
        from(i in Auth.Identity,
          where: i.provider_id == ^provider.id,
          join: a in Domain.Actors.Actor,
          on: i.actor_id == a.id,
          select: %{
            identity_id: i.id,
            actor_name: a.name,
            provider_identifier: i.provider_identifier
          }
        )
        |> Repo.all()

      # Process each identity
      Enum.flat_map(identities, fn identity ->
        try do
          case Repo.update_all(
                 from(i in Auth.Identity, where: i.id == ^identity.identity_id),
                 set: [
                   name: identity.actor_name,
                   idp_id: identity.provider_identifier,
                   issuer: issuer,
                   provider_id: nil
                 ]
               ) do
            {1, _} ->
              []

            {0, _} ->
              [
                %{
                  identity_id: identity.identity_id,
                  actor_name: identity.actor_name,
                  provider_identifier: identity.provider_identifier,
                  issuer: issuer,
                  error: "Identity not found"
                }
              ]
          end
        rescue
          e in Postgrex.Error ->
            [
              %{
                identity_id: identity.identity_id,
                actor_name: identity.actor_name,
                provider_identifier: identity.provider_identifier,
                issuer: issuer,
                error: "Constraint violation (skipped): #{Exception.message(e)}"
              }
            ]
        end
      end)
    end)
  end

  defp migrate_actor_groups(%Auth.Subject{} = subject) do
    # Get all actor groups for the account with their providers
    groups =
      from(g in Domain.Actors.Group,
        where: g.account_id == ^subject.account.id,
        left_join: p in Auth.Provider,
        on: g.provider_id == p.id,
        select: %{
          group_id: g.id,
          group_name: g.name,
          provider_id: g.provider_id,
          provider_identifier: g.provider_identifier,
          provider_adapter: p.adapter,
          provider_adapter_state: p.adapter_state
        }
      )
      |> Repo.all()

    # Process each group
    Enum.flat_map(groups, fn group ->
      {directory, idp_id} =
        cond do
          # No provider - set issuer to 'firezone'
          is_nil(group.provider_id) or is_nil(group.provider_identifier) ->
            {"firezone", nil}

          # Google Workspace
          group.provider_adapter == :google_workspace ->
            domain = get_in(group.provider_adapter_state, ["claims", "hd"])
            {"g:#{domain}", group.provider_identifier}

          # Okta
          group.provider_adapter == :okta ->
            "https://" <> okta_domain = get_in(group.provider_adapter_state, ["claims", "iss"])

            {"o:#{okta_domain}", group.provider_identifier}

          # Microsoft Entra
          group.provider_adapter == :microsoft_entra ->
            tenant_id = get_in(group.provider_adapter_state, ["claims", "tid"])

            {"e:#{tenant_id}", group.provider_identifier}

          # Unknown adapter type - log error and skip
          true ->
            {nil, nil}
        end

      # Skip groups where issuer is nil
      if is_nil(directory) do
        [
          %{
            group_id: group.group_id,
            group_name: group.group_name,
            provider_adapter: group.provider_adapter,
            directory: directory,
            idp_id: idp_id,
            error: "Skipped - unable to determine directory"
          }
        ]
      else
        # Update the group
        try do
          case Repo.update_all(
                 from(g in Domain.Actors.Group, where: g.id == ^group.group_id),
                 set: [
                   directory: directory,
                   idp_id: idp_id,
                   provider_id: nil,
                   provider_identifier: nil
                 ]
               ) do
            {1, _} ->
              []

            {0, _} ->
              [
                %{
                  group_id: group.group_id,
                  group_name: group.group_name,
                  provider_adapter: group.provider_adapter,
                  directory: directory,
                  idp_id: idp_id,
                  error: "Group not found"
                }
              ]
          end
        rescue
          e in Postgrex.Error ->
            [
              %{
                group_id: group.group_id,
                group_name: group.group_name,
                provider_adapter: group.provider_adapter,
                directory: directory,
                idp_id: idp_id,
                error: "Constraint violation (skipped): #{Exception.message(e)}"
              }
            ]
        end
      end
    end)
  end

  defp handle_duplicate_identity_emails(account) do
    # Find all identities with their actors, grouped by provider_id and email
    identities_with_actors =
      from(i in Auth.Identity,
        where: i.account_id == ^account.id,
        join: a in Domain.Actors.Actor,
        on: i.actor_id == a.id,
        select: %{
          identity_id: i.id,
          identity_email: i.email,
          provider_identifier: i.provider_identifier,
          provider_state: i.provider_state,
          provider_id: i.provider_id,
          actor_id: a.id,
          actor_type: a.type,
          actor_disabled_at: a.disabled_at,
          actor_inserted_at: a.inserted_at
        },
        order_by: [asc: i.provider_id, desc: a.inserted_at]
      )
      |> Repo.all()
      |> Enum.map(fn identity ->
        Map.put(identity, :extracted_email, extract_email_from_identity(identity))
      end)
      |> Enum.reject(fn identity -> is_nil(identity.extracted_email) end)

    # Group by provider_id and extracted email
    grouped =
      identities_with_actors
      |> Enum.group_by(fn i -> {i.provider_id, i.extracted_email} end)

    # Process duplicates
    Enum.flat_map(grouped, fn {{_provider_id, email}, identities} ->
      if length(identities) > 1 do
        handle_duplicate_group(email, identities)
      else
        []
      end
    end)
  end

  defp handle_duplicate_group(base_email, identities) do
    # Find the preferred identity (most recent account_admin_user, or most recent enabled actor)
    preferred =
      Enum.find(identities, fn i ->
        i.actor_type == :account_admin_user
      end) ||
        Enum.find(identities, fn i ->
          is_nil(i.actor_disabled_at)
        end) ||
        List.first(identities)

    # Set the preferred actor's email to the base email
    errors =
      case update_actor_email(preferred.actor_id, base_email) do
        :ok -> []
        {:error, error} -> [error]
      end

    # For the remaining duplicates, append +firezone-migrated-<i> to their emails
    remaining = Enum.reject(identities, fn i -> i.identity_id == preferred.identity_id end)

    (errors ++
       Enum.with_index(remaining, 1))
    |> Enum.flat_map(fn {identity, index} ->
      modified_email = modify_email_for_duplicate(base_email, index)

      case update_actor_email(identity.actor_id, modified_email) do
        :ok -> []
        {:error, error} -> [error]
      end
    end)
  end

  defp modify_email_for_duplicate(email, index) do
    [local, domain] = String.split(email, "@", parts: 2)
    "#{local}+firezone-migrated-#{index}@#{domain}"
  end

  defp populate_actor_emails_from_identities(account) do
    from(a in Domain.Actors.Actor,
      where: a.account_id == ^account.id and is_nil(a.email),
      join: i in Auth.Identity,
      on: i.actor_id == a.id,
      select: %{
        actor_id: a.id,
        identity_email: i.email,
        provider_identifier: i.provider_identifier,
        provider_state: i.provider_state
      },
      distinct: a.id
    )
    |> Repo.all()
    |> Enum.flat_map(fn identity ->
      case extract_email_from_identity(identity) do
        nil ->
          []

        email ->
          case update_actor_email(identity.actor_id, email) do
            :ok -> []
            {:error, error} -> [error]
          end
      end
    end)
  end

  defp populate_service_account_emails(account) do
    from(a in Domain.Actors.Actor,
      where: a.account_id == ^account.id and a.type == :service_account and is_nil(a.email),
      select: {a.id, a.name}
    )
    |> Repo.all()
    |> Enum.flat_map(fn {actor_id, name} ->
      email = normalize_name_for_email(name) <> "@service-account.firezone.dev"

      case update_actor_email(actor_id, email) do
        :ok -> []
        {:error, error} -> [error]
      end
    end)
  end

  defp populate_api_client_emails(account) do
    from(a in Domain.Actors.Actor,
      where: a.account_id == ^account.id and a.type == :api_client and is_nil(a.email),
      select: {a.id, a.name}
    )
    |> Repo.all()
    |> Enum.flat_map(fn {actor_id, name} ->
      email = normalize_name_for_email(name) <> "@api-client.firezone.dev"

      case update_actor_email(actor_id, email) do
        :ok -> []
        {:error, error} -> [error]
      end
    end)
  end

  defp normalize_name_for_email(name) when is_binary(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9-]/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end

  defp normalize_name_for_email(nil), do: "unnamed"

  defp extract_email_from_identity(%{identity_email: email}) when not is_nil(email), do: email

  defp extract_email_from_identity(%{provider_identifier: identifier} = identity)
       when not is_nil(identifier) do
    if String.contains?(identifier, "@") do
      identifier
    else
      extract_email_from_provider_state(identity)
    end
  end

  defp extract_email_from_identity(identity) do
    extract_email_from_provider_state(identity)
  end

  defp extract_email_from_provider_state(%{provider_state: provider_state})
       when is_map(provider_state) do
    find_email_in_map(provider_state)
  end

  defp extract_email_from_provider_state(_), do: nil

  defp find_email_in_map(map) when is_map(map) do
    email_regex = Auth.email_regex()

    Enum.find_value(map, fn
      {_key, value} when is_binary(value) ->
        if String.contains?(value, "@") and Regex.match?(email_regex, value) do
          value
        else
          nil
        end

      {_key, value} when is_map(value) ->
        find_email_in_map(value)

      _ ->
        nil
    end)
  end

  defp update_actor_email(actor_id, email) do
    try do
      case Repo.update_all(
             from(a in Domain.Actors.Actor, where: a.id == ^actor_id),
             set: [email: email]
           ) do
        {1, _} ->
          :ok

        {0, _} ->
          {:error, %{actor_id: actor_id, email: email, error: "Actor not found"}}

        _other ->
          {:error, %{actor_id: actor_id, email: email, error: "Unexpected update result"}}
      end
    rescue
      e in Postgrex.Error ->
        {:error,
         %{
           actor_id: actor_id,
           email: email,
           error: "Constraint violation: #{Exception.message(e)}"
         }}
    end
  end

  defp migrate_oidc_providers(%Auth.Subject{} = subject) do
    # Get all legacy openid_connect providers
    legacy_providers =
      from(p in Auth.Provider,
        where: p.account_id == ^subject.account.id and p.adapter == :openid_connect,
        select: %{
          id: p.id,
          name: p.name,
          disabled_at: p.disabled_at,
          is_default: not is_nil(p.assigned_default_at),
          adapter_config: p.adapter_config,
          adapter_state: p.adapter_state
        }
      )
      |> Repo.all()

    # Process each legacy provider
    Enum.flat_map(legacy_providers, fn provider ->
      # Try to extract issuer from multiple sources:
      # 1. From adapter_state (if available)
      # 2. From linked identities' provider_state
      # 3. From discovery_document_uri (fallback)
      issuer =
        cond do
          # Check adapter_state first
          not is_nil(get_in(provider.adapter_state, ["claims", "iss"])) ->
            get_in(provider.adapter_state, ["claims", "iss"])

          # Try to get from an identity
          true ->
            from(i in Auth.Identity,
              where: i.provider_id == ^provider.id and not is_nil(i.provider_state),
              select: i.provider_state,
              limit: 1
            )
            |> Repo.one()
            |> case do
              nil ->
                # Fallback: try to extract from discovery_document_uri
                # Most OIDC discovery URIs are in format: {issuer}/.well-known/openid-configuration
                discovery_uri = get_in(provider.adapter_config, ["discovery_document_uri"])

                if discovery_uri do
                  discovery_uri
                  |> String.replace(~r/\/.well-known\/.*$/, "")
                  |> String.replace(~r/\/$/, "")
                else
                  nil
                end

              provider_state ->
                get_in(provider_state, ["claims", "iss"])
            end
        end

      # Skip if no issuer found
      if is_nil(issuer) do
        [
          %{
            provider_id: provider.id,
            provider_name: provider.name,
            error: "No issuer found - tried adapter_state, identities, and discovery_document_uri"
          }
        ]
      else
        # Extract config fields
        client_id = get_in(provider.adapter_config, ["client_id"])
        client_secret = get_in(provider.adapter_config, ["client_secret"])
        discovery_document_uri = get_in(provider.adapter_config, ["discovery_document_uri"])

        # Create the new OIDC auth provider
        try do
          # First create the base auth_provider record
          {:ok, _base_provider} =
            Repo.insert(%Domain.AuthProviders.AuthProvider{
              id: provider.id,
              account_id: subject.account.id
            })

          # Then create the OIDC-specific record
          {:ok, _oidc_provider} =
            Repo.insert(%Domain.OIDC.AuthProvider{
              id: provider.id,
              account_id: subject.account.id,
              name: provider.name,
              issuer: issuer,
              client_id: client_id,
              client_secret: client_secret,
              discovery_document_uri: discovery_document_uri,
              is_disabled: not is_nil(provider.disabled_at),
              is_default: not is_nil(provider.assigned_default_at),
              context: :clients_and_portal,
              created_by: :system
            })

          []
        rescue
          e ->
            [
              %{
                provider_id: provider.id,
                provider_name: provider.name,
                issuer: issuer,
                error: Exception.message(e)
              }
            ]
        end
      end
    end)
  end

  defp migrate_google_providers(%Auth.Subject{} = subject) do
    # Get all legacy google_workspace providers
    legacy_providers =
      from(p in Auth.Provider,
        where: p.account_id == ^subject.account.id and p.adapter == :google_workspace,
        select: %{
          id: p.id,
          name: p.name,
          disabled_at: p.disabled_at,
          is_default: not is_nil(p.assigned_default_at),
          adapter_state: p.adapter_state
        }
      )
      |> Repo.all()

    # Process each legacy provider
    Enum.flat_map(legacy_providers, fn provider ->
      # Extract hosted domain from adapter_state
      issuer = get_in(provider.adapter_state, ["claims", "iss"])
      client_id = get_in(provider.adapter_config, ["client_id"])
      client_secret = get_in(provider.adapter_config, ["client_secret"])
      discovery_document_uri = get_in(provider.adapter_config, ["discovery_document_uri"])

      # Create the new Google auth provider
      try do
        # First create the base auth_provider record
        {:ok, _base_provider} =
          Repo.insert(%Domain.AuthProviders.AuthProvider{
            id: provider.id,
            account_id: subject.account.id
          })

        # Then create the Google-specific record
        {:ok, _google_provider} =
          Repo.insert(%Domain.OIDC.AuthProvider{
            id: provider.id,
            account_id: subject.account.id,
            name: provider.name,
            issuer: issuer,
            client_id: client_id,
            client_secret: client_secret,
            discovery_document_uri: discovery_document_uri,
            is_disabled: not is_nil(provider.disabled_at),
            is_default: not is_nil(provider.assigned_default_at),
            context: :clients_and_portal,
            created_by: :system
          })

        []
      rescue
        e ->
          [
            %{
              provider_id: provider.id,
              provider_name: provider.name,
              error: Exception.message(e)
            }
          ]
      end
    end)
  end

  defp migrate_entra_providers(%Auth.Subject{} = subject) do
    # Get all legacy microsoft_entra providers
    legacy_providers =
      from(p in Auth.Provider,
        where: p.account_id == ^subject.account.id and p.adapter == :microsoft_entra,
        select: %{
          id: p.id,
          name: p.name,
          disabled_at: p.disabled_at,
          is_default: not is_nil(p.assigned_default_at),
          adapter_state: p.adapter_state
        }
      )
      |> Repo.all()

    # Process each legacy provider
    Enum.flat_map(legacy_providers, fn provider ->
      # Extract issuer and tenant_id from adapter_state
      issuer = get_in(provider.adapter_state, ["claims", "iss"])
      client_id = get_in(provider.adapter_config, ["client_id"])
      client_secret = get_in(provider.adapter_config, ["client_secret"])
      discovery_document_uri = get_in(provider.adapter_config, ["discovery_document_uri"])

      # Create the new Entra auth provider
      try do
        # First create the base auth_provider record
        {:ok, _base_provider} =
          Repo.insert(%Domain.AuthProviders.AuthProvider{
            id: provider.id,
            account_id: subject.account.id
          })

        # Then create the Entra-specific record
        {:ok, _entra_provider} =
          Repo.insert(%Domain.OIDC.AuthProvider{
            id: provider.id,
            account_id: subject.account.id,
            name: provider.name,
            issuer: issuer,
            client_id: client_id,
            client_secret: client_secret,
            discovery_document_uri: discovery_document_uri,
            is_disabled: not is_nil(provider.disabled_at),
            is_default: not is_nil(provider.assigned_default_at),
            context: :clients_and_portal,
            created_by: :system
          })

        []
      rescue
        e ->
          [
            %{
              provider_id: provider.id,
              provider_name: provider.name,
              issuer: issuer,
              error: Exception.message(e)
            }
          ]
      end
    end)
  end

  defp migrate_okta_providers(%Auth.Subject{} = subject) do
    # Get all legacy okta providers
    legacy_providers =
      from(p in Auth.Provider,
        where: p.account_id == ^subject.account.id and p.adapter == :okta,
        select: %{
          id: p.id,
          name: p.name,
          disabled_at: p.disabled_at,
          is_default: not is_nil(p.assigned_default_at),
          adapter_config: p.adapter_config,
          adapter_state: p.adapter_state
        }
      )
      |> Repo.all()

    # Process each legacy provider
    Enum.flat_map(legacy_providers, fn provider ->
      # Extract issuer from adapter_state (from claims if available)
      issuer = get_in(provider.adapter_state, ["claims", "iss"])

      # Skip if no issuer found
      if is_nil(issuer) do
        [
          %{
            provider_id: provider.id,
            provider_name: provider.name,
            error: "No issuer found in adapter_state"
          }
        ]
      else
        # Extract config fields if available
        client_id = get_in(provider.adapter_config, ["client_id"])
        client_secret = get_in(provider.adapter_config, ["client_secret"])
        discovery_document_uri = get_in(provider.adapter_config, ["discovery_document_uri"])

        # Create OIDC auth provider (not Okta-specific) since we don't have all required Okta fields
        try do
          # First create the base auth_provider record
          {:ok, _base_provider} =
            Repo.insert(%Domain.AuthProviders.AuthProvider{
              id: provider.id,
              account_id: subject.account.id
            })

          # Then create the OIDC-specific record
          {:ok, _oidc_provider} =
            Repo.insert(%Domain.OIDC.AuthProvider{
              id: provider.id,
              account_id: subject.account.id,
              name: provider.name,
              issuer: issuer,
              client_id: client_id,
              client_secret: client_secret,
              discovery_document_uri: discovery_document_uri,
              is_disabled: not is_nil(provider.disabled_at),
              is_default: not is_nil(provider.assigned_default_at),
              context: :clients_and_portal,
              created_by: :system
            })

          []
        rescue
          e ->
            [
              %{
                provider_id: provider.id,
                provider_name: provider.name,
                issuer: issuer,
                error: Exception.message(e)
              }
            ]
        end
      end
    end)
  end

  defp migrate_email_provider(%Auth.Subject{} = subject) do
    # Email provider
    if legacy_email_provider = legacy_email_otp_provider(subject.account) do
      # First create the base auth_provider record using Repo directly
      {:ok, _base_provider} =
        Repo.insert(%AuthProviders.AuthProvider{
          id: legacy_email_provider.id,
          account_id: subject.account.id
        })

      # Then create the EmailOTP-specific record using Safe
      changeset =
        %EmailOTP.AuthProvider{
          id: legacy_email_provider.id,
          account_id: subject.account.id,
          name: "Email OTP",
          context: :clients_and_portal,
          is_disabled: not is_nil(legacy_email_provider.disabled_at)
        }
        |> Ecto.Changeset.change()
        |> EmailOTP.AuthProvider.changeset()

      case Safe.scoped(subject) |> Safe.insert(changeset) do
        {:ok, _provider} -> :ok
        {:error, reason} -> raise "Failed to create email provider: #{inspect(reason)}"
      end
    end
  end

  defp migrate_userpass_provider(%Auth.Subject{} = subject) do
    # Userpass provider
    if legacy_userpass_provider = legacy_userpass_provider(subject.account) do
      # First create the base auth_provider record using Repo directly
      {:ok, _base_provider} =
        Repo.insert(%AuthProviders.AuthProvider{
          id: legacy_userpass_provider.id,
          account_id: subject.account.id
        })

      # Then create the Userpass-specific record using Safe
      changeset =
        %Userpass.AuthProvider{
          id: legacy_userpass_provider.id,
          account_id: subject.account.id,
          name: "Username & Password",
          context: :clients_and_portal,
          is_disabled: not is_nil(legacy_userpass_provider.disabled_at)
        }
        |> Ecto.Changeset.change()
        |> Userpass.AuthProvider.changeset()

      case Safe.scoped(subject) |> Safe.insert(changeset) do
        {:ok, _provider} -> :ok
        {:error, reason} -> raise "Failed to create userpass provider: #{inspect(reason)}"
      end
    end
  end

  defp delete_legacy_providers(%Auth.Subject{} = subject) do
    # Delete all legacy Auth.Provider records for this account
    # This includes all adapters: email, userpass, mock, openid_connect, google_workspace, microsoft_entra, and okta
    from(p in Auth.Provider,
      where: p.account_id == ^subject.account.id
    )
    |> Repo.delete_all()
  end

  def down(%Accounts.Account{} = _account) do
  end

  def migrated?(%Accounts.Account{} = account) do
    from(p in EmailOTP.AuthProvider, where: p.account_id == ^account.id)
    |> Repo.exists?()
  end
end
