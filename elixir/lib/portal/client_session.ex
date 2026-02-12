defmodule Portal.ClientSession do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          id: Ecto.UUID.t() | nil,
          account_id: Ecto.UUID.t(),
          client_id: Ecto.UUID.t(),
          client_token_id: Ecto.UUID.t(),
          user_agent: String.t() | nil,
          remote_ip: :inet.ip_address() | nil,
          remote_ip_location_region: String.t() | nil,
          remote_ip_location_city: String.t() | nil,
          public_key: String.t() | nil,
          remote_ip_location_lat: float() | nil,
          remote_ip_location_lon: float() | nil,
          version: String.t() | nil,
          inserted_at: DateTime.t() | nil
        }

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "client_sessions" do
    belongs_to :account, Portal.Account, primary_key: true
    field :id, :binary_id, primary_key: true, autogenerate: true

    belongs_to :client, Portal.Client, references: :id
    belongs_to :client_token, Portal.ClientToken, references: :id

    field :public_key, :string
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
    |> validate_required([:account_id, :client_id, :client_token_id])
    |> assoc_constraint(:account)
    |> assoc_constraint(:client)
    |> assoc_constraint(:client_token)
  end
end
