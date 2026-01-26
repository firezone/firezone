defmodule Portal.IPv4Address do
  use Ecto.Schema
  import Ecto.Changeset
  alias Portal.Repo
  require Logger

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{
          account_id: Ecto.UUID.t(),
          address: Postgrex.INET.t(),
          client_id: Ecto.UUID.t() | nil,
          gateway_id: Ecto.UUID.t() | nil,
          inserted_at: DateTime.t()
        }

  # Encompasses all of CGNAT
  @reserved_cidr %Postgrex.INET{address: {100, 64, 0, 0}, netmask: 10}

  # For generating new IPs for clients and gateways
  @device_cidr %Postgrex.INET{address: {100, 64, 0, 0}, netmask: 11}

  schema "ipv4_addresses" do
    belongs_to :account, Portal.Account, primary_key: true
    field :address, Portal.Types.IP, primary_key: true

    belongs_to :client, Portal.Client
    belongs_to :gateway, Portal.Gateway

    timestamps(updated_at: false)
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> assoc_constraint(:account)
    |> assoc_constraint(:client)
    |> assoc_constraint(:gateway)
    |> check_constraint(:address_is_ipv4)
    |> check_constraint(:belongs_to_client_xor_gateway)
  end

  def reserved_cidr, do: @reserved_cidr

  def device_cidr, do: @device_cidr

  @doc """
  Allocates the next available IPv4 address for a client or gateway.

  This function calls a PL/pgSQL function that atomically:
  1. Finds next available candidate using MAX(address) + 1 within the specified CIDR
  2. Inserts the address into ipv4_addresses with the client_id or gateway_id
  3. Handles collisions with existing addresses by retrying

  Returns `{:ok, %IPv4Address{}}` on success or `{:error, reason}` on failure.

  ## Options
    * `:client_id` - The client ID to associate with the address
    * `:gateway_id` - The gateway ID to associate with the address
    * `:cidr` - Override the CIDR range for allocation (defaults to module's device CIDR)

  Exactly one of `:client_id` or `:gateway_id` must be provided.
  """
  def allocate_next_available_address(account_id, opts) do
    client_id = Keyword.get(opts, :client_id)
    gateway_id = Keyword.get(opts, :gateway_id)
    cidr = Keyword.get(opts, :cidr, @device_cidr)

    account_id_binary = Ecto.UUID.dump!(account_id)
    client_id_binary = if client_id, do: Ecto.UUID.dump!(client_id)
    gateway_id_binary = if gateway_id, do: Ecto.UUID.dump!(gateway_id)

    case Repo.query(
           "SELECT * FROM allocate_address($1, $2, $3, $4, $5)",
           [account_id_binary, "ipv4", cidr, client_id_binary, gateway_id_binary]
         ) do
      {:ok, %Postgrex.Result{rows: [[account_id, address, client_id, gateway_id, inserted_at]]}} ->
        {:ok,
         %__MODULE__{
           account_id: Ecto.UUID.load!(account_id),
           address: address,
           client_id: if(client_id, do: Ecto.UUID.load!(client_id)),
           gateway_id: if(gateway_id, do: Ecto.UUID.load!(gateway_id)),
           inserted_at: inserted_at
         }}

      {:error, error} ->
        Logger.error("Failed to allocate IPv4 address", account_id: account_id, error: error)
        {:error, error}
    end
  end
end
