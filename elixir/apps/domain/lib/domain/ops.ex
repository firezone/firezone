defmodule Domain.Ops do
  def create_and_provision_account(opts) do
    %{
      name: account_name,
      slug: account_slug,
      admin_name: account_admin_name,
      admin_email: account_admin_email
    } = Enum.into(opts, %{})

    Domain.Repo.transaction(fn ->
      {:ok, account} =
        Domain.Accounts.create_account(%{
          name: account_name,
          slug: account_slug
        })

      {:ok, account} = Domain.Billing.provision_account(account)

      {:ok, _everyone_group} =
        Domain.Actors.create_managed_group(account, %{
          name: "Everyone",
          membership_rules: [%{operator: true}]
        })

      {:ok, magic_link_provider} =
        Domain.Auth.create_provider(account, %{
          name: "Email",
          adapter: :email,
          adapter_config: %{}
        })

      {:ok, actor} =
        Domain.Actors.create_actor(account, %{
          type: :account_admin_user,
          name: account_admin_name
        })

      {:ok, identity} =
        Domain.Auth.upsert_identity(actor, magic_link_provider, %{
          provider_identifier: account_admin_email,
          provider_identifier_confirmation: account_admin_email
        })

      %{account: account, provider: magic_link_provider, actor: actor, identity: identity}
    end)
  end

  def provision_support_by_account_slug(account_slug) do
    Domain.Repo.transaction(fn ->
      {:ok, account} = Domain.Accounts.fetch_account_by_id_or_slug(account_slug)
      {:ok, providers} = Domain.Auth.list_active_providers_for_account(account)
      magic_link_provider = Enum.find(providers, fn provider -> provider.adapter == :email end)

      {:ok, actor} =
        Domain.Actors.create_actor(account, %{type: :account_admin_user, name: "Firezone Support"})

      {:ok, identity} =
        Domain.Auth.upsert_identity(actor, magic_link_provider, %{
          provider_identifier: "ent-support@firezone.dev",
          provider_identifier_confirmation: "ent-support@firezone.dev"
        })

      {actor, identity}
    end)
  end
end
