defmodule Portal.Accounts.Limits do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
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
    # Throughput each Relay allows per direction of a relayed connection; nil
    # or 0 is unlimited.
    field :relay_throughput_mbps, :integer
  end

  @doc """
  Returns the account's allocation quota on each Relay, or `nil` for unlimited.

  The quota is derived from existing account entitlements, not stored separately
  or read from Relay-specific Stripe metadata:

      seats * devices_per_actor + adhoc_service_accounts + 10 + div(seats, 10)

  `seats` is the configured `monthly_active_users_count` allowance when present,
  otherwise `users_count`. It is not the observed number of monthly active users.
  `devices_per_actor` is `connected_devices_per_actor`. `adhoc_service_accounts`
  is `adhoc_service_accounts_count`: each add-on contributes one device, without
  multiplying by the normal device allowance. These accounts are seat-exempt;
  service accounts charged to a seat are already covered by the first term.
  An unlimited seat, device, or add-on allowance (`nil`) makes the quota unlimited.

  The final terms allow ten Gateways plus one more for each complete ten seats.
  Clients and Gateways share the resulting quota; Relay peer channels do not
  consume additional allocations. For example:

  * 6 seats with 3 devices each: 18 + 10 = 28 allocations.
  * 100 seats with 5 devices each: 500 + 10 + 10 = 520 allocations.
  * 100 active seats with 10 devices each: 1000 + 10 + 10 = 1020 allocations.
  * The same account with 10,000 add-on service accounts: 11,020 allocations.

  Both Relay initialization and account CDC updates use this calculation, so seat,
  device, and add-on allowance changes take effect without a backfill or Relay
  reconnect.
  """
  @spec relay_allocation_limit(%__MODULE__{} | nil) :: pos_integer() | nil
  def relay_allocation_limit(nil), do: nil

  def relay_allocation_limit(%__MODULE__{} = limits) do
    seats = limits.monthly_active_users_count || limits.users_count
    devices = limits.connected_devices_per_actor
    adhoc_service_accounts = limits.adhoc_service_accounts_count

    if is_integer(seats) and is_integer(devices) and is_integer(adhoc_service_accounts) do
      seats * devices + adhoc_service_accounts + 10 + div(seats, 10)
    end
  end

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
      relay_throughput_mbps
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
    |> validate_number(:relay_throughput_mbps, greater_than_or_equal_to: 0)
  end
end
