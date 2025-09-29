defmodule Domain.Migrator do
  @moduledoc """
    This module handles migrating from the old auth system to the new
    directory-based system. This module can be removed once all customers
    have completed the migration.
  """

  alias Domain.{
    Accounts,
    Email
  }

  def up(%Accounts.Account{} = _account) do
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
    #    Create okta_auth_provider and okta_directory where org_domain comes from iss
    #    Update all policy conditions to point to the new auth_provider_id
    #    If was default, make this the new default
    #    For all auth_identities with iss and sub, copy this to issuer and subject. If not, delete the auth_identity
    #    For all actor_groups associated to this provider, copy issuer and provider_identifier minus G: and OU: prefixes off subject
    # 8. Update all auth_providers to disabled, disable sync, update all provider_id to NULL on auth_identities and actor_groups in account
    # 9. Show summary / done
  end

  def down(%Accounts.Account{} = _account) do
  end

  def migrated?(%Accounts.Account{} = account) do
    case Email.fetch_auth_provider_by_account(account) do
      {:ok, _auth_provider} -> true
      {:error, :not_found} -> false
    end
  end
end
