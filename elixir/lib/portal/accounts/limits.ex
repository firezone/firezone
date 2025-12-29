defmodule Portal.Accounts.Limits do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :users_count, :integer
    field :monthly_active_users_count, :integer
    field :service_accounts_count, :integer
    field :sites_count, :integer
    field :account_admin_users_count, :integer
    field :api_clients_count, :integer, default: 100
    field :api_tokens_per_client_count, :integer, default: 100
  end

  def changeset(limits \\ %__MODULE__{}, attrs) do
    fields = ~w[
      users_count
      monthly_active_users_count
      service_accounts_count
      sites_count
      account_admin_users_count
      api_clients_count
      api_tokens_per_client_count
    ]a

    limits
    |> cast(attrs, fields)
    |> validate_number(:users_count, greater_than_or_equal_to: 0)
    |> validate_number(:monthly_active_users_count, greater_than_or_equal_to: 0)
    |> validate_number(:service_accounts_count, greater_than_or_equal_to: 0)
    |> validate_number(:sites_count, greater_than_or_equal_to: 0)
    |> validate_number(:account_admin_users_count, greater_than_or_equal_to: 0)
    |> validate_number(:api_clients_count, greater_than_or_equal_to: 0)
    |> validate_number(:api_tokens_per_client_count, greater_than_or_equal_to: 0)
  end
end
