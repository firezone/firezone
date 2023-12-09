defmodule Domain.Ops do
  def provision_account(%{
        account_name: account_name,
        account_slug: account_slug,
        account_admin_name: account_admin_name,
        account_admin_email: account_admin_email
      }) do
    Domain.Repo.transaction(fn ->
      {:ok, account} = Domain.Accounts.create_account(%{name: account_name, slug: account_slug})

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
end
