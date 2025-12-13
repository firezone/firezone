defmodule Domain.PortalSession do
  use Ecto.Schema

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "portal_sessions" do
    belongs_to :account, Domain.Account, primary_key: true
    field :id, :binary_id, primary_key: true, autogenerate: true

    belongs_to :actor, Domain.Actor
    belongs_to :auth_provider, Domain.AuthProvider

    field :user_agent, :string
    field :remote_ip, Domain.Types.IP
    field :remote_ip_location_region, :string
    field :remote_ip_location_city, :string
    field :remote_ip_location_lat, :float
    field :remote_ip_location_lon, :float

    field :expires_at, :utc_datetime_usec

    # Allows for convenient mapping of the corresponding auth provider for display
    field :auth_provider_name, :string, virtual: true
    field :auth_provider_type, :string, virtual: true

    timestamps(updated_at: false)
  end
end
