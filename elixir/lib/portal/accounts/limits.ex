defmodule Portal.Accounts.Limits do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  @type t :: %__MODULE__{}
  embedded_schema do
    field :users_count, :integer
    field :monthly_active_users_count, :integer
    field :service_accounts_count, :integer
    # Sold as "additional service account + device": this many active service
    # accounts take no seat, the others take a seat each.
    field :adhoc_service_accounts_count, :integer, default: 0
    field :sites_count, :integer
    field :account_admin_users_count, :integer
    field :connected_devices_per_actor, :integer
    field :api_clients_count, :integer, default: 100
    field :api_tokens_per_client_count, :integer, default: 100
    field :api_refill_rate, :integer
    field :api_capacity, :integer
    field :api_read_refill_rate, :integer
    field :api_read_capacity, :integer
    field :ingestion_refill_rate, :integer
    field :ingestion_capacity, :integer
  end

  # Every plan includes this many active service accounts that take no seat,
  # on top of whatever ad-hoc allowance was bought. One is enough for the
  # service account a customer runs their routing devices under.
  @free_service_accounts 1

  @doc """
  How many active service accounts take no seat: the bought ad-hoc allowance
  plus the one every plan includes. `nil` means unlimited.
  """
  @spec adhoc_service_accounts_allowance(t() | nil) :: non_neg_integer() | nil
  def adhoc_service_accounts_allowance(%__MODULE__{adhoc_service_accounts_count: nil}), do: nil

  def adhoc_service_accounts_allowance(%__MODULE__{adhoc_service_accounts_count: bought}),
    do: bought + @free_service_accounts

  def adhoc_service_accounts_allowance(nil), do: @free_service_accounts

  def changeset(limits \\ %__MODULE__{}, attrs) do
    fields = ~w[
      users_count
      monthly_active_users_count
      service_accounts_count
      adhoc_service_accounts_count
      sites_count
      account_admin_users_count
      connected_devices_per_actor
      api_clients_count
      api_tokens_per_client_count
      api_refill_rate
      api_capacity
      api_read_refill_rate
      api_read_capacity
      ingestion_refill_rate
      ingestion_capacity
    ]a

    limits
    |> cast(attrs, fields)
    |> validate_number(:users_count, greater_than_or_equal_to: 0)
    |> validate_number(:monthly_active_users_count, greater_than_or_equal_to: 0)
    |> validate_number(:service_accounts_count, greater_than_or_equal_to: 0)
    |> validate_number(:adhoc_service_accounts_count, greater_than_or_equal_to: 0)
    |> validate_number(:sites_count, greater_than_or_equal_to: 0)
    |> validate_number(:account_admin_users_count, greater_than_or_equal_to: 0)
    |> validate_number(:connected_devices_per_actor, greater_than_or_equal_to: 0)
    |> validate_number(:api_clients_count, greater_than_or_equal_to: 0)
    |> validate_number(:api_tokens_per_client_count, greater_than_or_equal_to: 0)
    |> validate_number(:api_read_refill_rate, greater_than_or_equal_to: 0)
    |> validate_number(:api_read_capacity, greater_than_or_equal_to: 0)
    |> validate_number(:ingestion_refill_rate, greater_than_or_equal_to: 0)
    |> validate_number(:ingestion_capacity, greater_than_or_equal_to: 0)
  end
end
