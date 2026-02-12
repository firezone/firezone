defmodule Portal.GatewaySession do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          account_id: Ecto.UUID.t(),
          gateway_id: Ecto.UUID.t(),
          gateway_token_id: Ecto.UUID.t(),
          user_agent: String.t() | nil,
          remote_ip: :inet.ip_address() | nil,
          remote_ip_location_region: String.t() | nil,
          remote_ip_location_city: String.t() | nil,
          remote_ip_location_lat: float() | nil,
          remote_ip_location_lon: float() | nil,
          version: String.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "gateway_sessions" do
    belongs_to :account, Portal.Account, primary_key: true
    field :id, :binary_id, primary_key: true, autogenerate: true

    belongs_to :gateway, Portal.Gateway, references: :id
    belongs_to :gateway_token, Portal.GatewayToken, references: :id

    field :user_agent, :string
    field :remote_ip, Portal.Types.IP
    field :remote_ip_location_region, :string
    field :remote_ip_location_city, :string
    field :remote_ip_location_lat, :float
    field :remote_ip_location_lon, :float
    field :version, :string

    timestamps(updated_at: false)
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([:account_id, :gateway_id, :gateway_token_id])
    |> assoc_constraint(:account)
    |> assoc_constraint(:gateway)
    |> assoc_constraint(:gateway_token)
  end
end
