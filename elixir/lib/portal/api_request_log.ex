defmodule Portal.APIRequestLog do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          account_id: Ecto.UUID.t(),
          event_id: String.t(),
          actor_id: Ecto.UUID.t(),
          api_token_id: Ecto.UUID.t(),
          method: String.t(),
          path: String.t(),
          content_length: integer() | nil,
          request_id: String.t(),
          user_agent: String.t() | nil,
          remote_ip: Postgrex.INET.t(),
          remote_ip_location_region: String.t() | nil,
          remote_ip_location_city: String.t() | nil,
          remote_ip_location_lat: float() | nil,
          remote_ip_location_lon: float() | nil,
          inserted_at: DateTime.t()
        }

  @primary_key false
  @foreign_key_type :binary_id

  schema "api_request_logs" do
    belongs_to :account, Portal.Account, primary_key: true
    field :event_id, Portal.Types.EventId, primary_key: true

    field :actor_id, :binary_id
    field :api_token_id, :binary_id

    field :method, :string
    field :path, :string
    field :content_length, :integer
    field :request_id, :string

    field :user_agent, :string
    field :remote_ip, Portal.Types.IP
    field :remote_ip_location_region, :string
    field :remote_ip_location_city, :string
    field :remote_ip_location_lat, :float
    field :remote_ip_location_lon, :float

    field :inserted_at, :utc_datetime_usec, read_after_writes: true
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([
      :account_id,
      :event_id,
      :actor_id,
      :api_token_id,
      :method,
      :path,
      :request_id,
      :remote_ip
    ])
    |> validate_length(:user_agent, max: 255)
    |> validate_length(:request_id, max: 255)
    |> validate_length(:remote_ip_location_region, max: 255)
    |> validate_length(:remote_ip_location_city, max: 255)
    |> assoc_constraint(:account)
  end
end
