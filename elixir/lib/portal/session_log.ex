defmodule Portal.SessionLog do
  # credo:disable-for-this-file Credo.Check.Warning.MissingChangesetFunction
  use Ecto.Schema

  @primary_key false
  @foreign_key_type :binary_id

  schema "session_logs" do
    belongs_to :account, Portal.Account, primary_key: true
    field :event_id, Portal.Types.EventId, primary_key: true
    field :timestamp, :utc_datetime_usec
    field :lsn, :integer
    field :context, Ecto.Enum, values: [:client, :gateway, :portal]

    field :actor_id, :binary_id
    field :actor_email, :string
    field :device_id, :binary_id
    field :token_id, :binary_id
    field :auth_provider_id, :binary_id

    field :user_agent, :string
    field :remote_ip, Portal.Types.IP
    field :remote_ip_location_region, :string
    field :remote_ip_location_city, :string
    field :remote_ip_location_lat, :float
    field :remote_ip_location_lon, :float
  end
end
