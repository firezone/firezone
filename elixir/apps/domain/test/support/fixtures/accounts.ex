defmodule Domain.Fixtures.Accounts do
  use Domain.Fixture
  alias Domain.Repo
  alias Domain.Accounts

  def account_attrs(attrs \\ %{}) do
    unique_num = unique_integer()

    Enum.into(attrs, %{
      name: "acc-#{unique_num}",
      legal_name: "l-acc-#{unique_num}",
      slug: "acc_#{unique_num}",
      config: %{
        clients_upstream_dns: [
          %{protocol: "ip_port", address: "1.1.1.1"},
          %{protocol: "ip_port", address: "2606:4700:4700::1111"},
          %{protocol: "ip_port", address: "8.8.8.8:853"}
        ]
      },
      features: %{
        flow_activities: true,
        policy_conditions: true,
        multi_site_resources: true,
        traffic_filters: true,
        self_hosted_relays: true,
        idp_sync: true,
        rest_api: true
      },
      limits: %{
        monthly_active_users_count: 100
      },
      metadata: %{
        stripe: %{}
      }
    })
  end

  def create_account(attrs \\ %{}) do
    attrs = account_attrs(attrs)
    {:ok, account} = Accounts.create_account(attrs)
    account
  end

  def delete_account(%Accounts.Account{} = account) do
    update_account(account, deleted_at: DateTime.utc_now())
  end

  def disable_account(%Accounts.Account{} = account) do
    update_account(account, disabled_at: DateTime.utc_now())
  end

  def change_to_enterprise(%Accounts.Account{} = account) do
    update_account(account, %{metadata: %{stripe: %{product_name: "Enterprise"}}})
  end

  def change_to_team(%Accounts.Account{} = account) do
    update_account(account, %{metadata: %{stripe: %{product_name: "Team"}}})
  end

  def change_to_starter(%Accounts.Account{} = account) do
    update_account(account, %{metadata: %{stripe: %{product_name: "Starter"}}})
  end

  def update_account(account, attrs \\ %{}) do
    account
    |> Ecto.Changeset.change(attrs)
    |> Repo.update!()
  end
end
