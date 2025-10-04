defmodule Domain.Migrator do
  @moduledoc """
    This module handles migrating from the old auth system to the new
    directory-based system. This module can be removed once all customers
    have completed the migration.
  """

  alias Domain.{
    Accounts
  }

  def up(%Accounts.Account{} = _account) do
    # 1. Create a Firezone directory
    # 2. If email/otp auth was enabled, create an email_auth_provider for the firezone directory,
    #    update all auth_identities and actor_groups with that directory_id, and disable the old one,
    #    update all policy conditions to point to the new auth_provider_id
    # 3. If userpass auth was enabled, create a userpass_auth_provider for the firezone directory,
    #    update all auth_identities and actor_groups with that directory_id, and disable the old one,
    #    update all policy conditions to point to the new auth_provider_id
    #    If was default, make this the new default
    # 4. Create a corresponding oidc_auth_provider for all existing generic oidc auth providers,
    #    update all auth_identities and actor_groups with that directory_id, and disable the old ones,
    #    update all policy conditions to point to the new auth_provider_id
    #    If was default, make this the new default
    # 5. For each enabled google workspace auth provider, create a corresponding google_directory and google_auth_provider in disabled states,
    #    update all auth_identities and actor_groups with that directory_id, and disable the old ones,
    #    update all policy conditions to point to the new auth_provider_id
    #    If was default, make this the new default
    # 6. For each enabled entra auth provider, create a corresponding entra_directory and entra_auth_provider in disabled states,
    #    update all auth_identities and actor_groups with that directory_id, and disable the old ones,
    #    update all policy conditions to point to the new auth_provider_id
    #    If was default, make this the new default
    # 7. For each enabled okta auth provider, create a corresponding okta_directory and okta_auth_provider in disabled states,
    #    update all auth_identities and actor_groups with that directory_id, and disable the old ones,
    #    update all policy conditions to point to the new auth_provider_id
    #    If was default, make this the new default
  end

  def down(%Accounts.Account{} = _account) do
  end
end
