defmodule Portal.AccountFixtures do
  @moduledoc """
  Test helpers for creating accounts and related data.
  """

  import Ecto.Changeset
  alias Portal.Repo

  @doc """
  Generate valid account attributes with sensible defaults.
  """
  def valid_account_attrs(attrs \\ %{}) do
    unique_num = System.unique_integer([:positive, :monotonic])

    Enum.into(attrs, %{
      name: "Account #{unique_num}",
      legal_name: "Legal Account #{unique_num}",
      slug: "account_#{unique_num}",
      config: %{
        clients_upstream_dns: %{
          type: :custom,
          addresses: [
            %{address: "1.1.1.1"},
            %{address: "2606:4700:4700::1111"},
            %{address: "9.9.9.9"}
          ]
        }
      },
      features: %{
        policy_conditions: true,
        multi_site_resources: true,
        traffic_filters: true,
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

  @doc """
  Generate an account with valid default attributes.

  ## Examples

      account = account_fixture()
      account = account_fixture(name: "Custom Account")

  """
  def account_fixture(attrs \\ %{}) do
    attrs = valid_account_attrs(attrs)

    %Portal.Account{}
    |> cast(attrs, [:name, :legal_name, :slug])
    |> cast_embed(:config)
    |> cast_embed(:features)
    |> cast_embed(:limits)
    |> cast_embed(:metadata)
    |> Repo.insert!()
  end

  @doc """
  Generate an account with a Starter plan.
  """
  def starter_account_fixture(attrs \\ %{}) do
    account = account_fixture(attrs)

    account
    |> cast(%{metadata: %{stripe: %{product_name: "Starter"}}}, [])
    |> cast_embed(:metadata)
    |> Repo.update!()
  end

  @doc """
  Generate an account with a Team plan.
  """
  def team_account_fixture(attrs \\ %{}) do
    account = account_fixture(attrs)

    account
    |> cast(%{metadata: %{stripe: %{product_name: "Team"}}}, [])
    |> cast_embed(:metadata)
    |> Repo.update!()
  end

  @doc """
  Generate an account with an Enterprise plan.
  """
  def enterprise_account_fixture(attrs \\ %{}) do
    account = account_fixture(attrs)

    account
    |> cast(%{metadata: %{stripe: %{product_name: "Enterprise"}}}, [])
    |> cast_embed(:metadata)
    |> Repo.update!()
  end

  @doc """
  Generate a disabled account.
  """
  def disabled_account_fixture(attrs \\ %{}) do
    account = account_fixture(attrs)

    account
    |> cast(%{disabled_at: DateTime.utc_now(), disabled_reason: "Testing"}, [
      :disabled_at,
      :disabled_reason
    ])
    |> Repo.update!()
  end

  @doc """
  Update an account with the given attributes.
  """
  def update_account(account, attrs) do
    attrs = Enum.into(attrs, %{})

    account
    |> cast(attrs, [:name, :legal_name, :slug, :disabled_at, :disabled_reason])
    |> cast_embed(:config)
    |> cast_embed(:features)
    |> cast_embed(:limits)
    |> cast_embed(:metadata)
    |> Repo.update!()
  end
end
