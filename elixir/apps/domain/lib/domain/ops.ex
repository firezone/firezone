defmodule Domain.Ops do
  def provision_account(%{
        account_name: account_name,
        account_slug: account_slug,
        account_admin_name: account_admin_name,
        account_admin_email: account_admin_email
      }) do
    Domain.Repo.transaction(fn ->
      {:ok, account} = Domain.Accounts.create_account(%{name: account_name, slug: account_slug})

      {:ok, _everyone_group} =
        Domain.Actors.create_managed_group(account, %{
          name: "Everyone",
          membership_rules: [%{operator: "all_users"}]
        })

      {:ok, magic_link_provider} =
        Domain.Auth.create_provider(account, %{
          name: "Email",
          adapter: :email,
          adapter_config: %{}
        })

      {:ok, actor} =
        Domain.Actors.create_actor(account, %{type: :account_admin_user, name: account_admin_name})

      {:ok, _identity} =
        Domain.Auth.upsert_identity(actor, magic_link_provider, %{
          provider_identifier: account_admin_email,
          provider_identifier_confirmation: account_admin_email
        })
    end)
  end

  def provision_support_by_account_slug(account_slug) do
    Domain.Repo.transaction(fn ->
      {:ok, account} = Domain.Accounts.fetch_account_by_id_or_slug(account_slug)
      {:ok, providers} = Domain.Auth.list_active_providers_for_account(account)
      magic_link_provider = Enum.find(providers, fn provider -> provider.adapter == :email end)

      {:ok, actor} =
        Domain.Actors.create_actor(account, %{type: :account_admin_user, name: "Firezone Support"})

      {:ok, _identity} =
        Domain.Auth.upsert_identity(actor, magic_link_provider, %{
          provider_identifier: "ent-support@firezone.dev",
          provider_identifier_confirmation: "ent-support@firezone.dev"
        })
    end)
  end
end
