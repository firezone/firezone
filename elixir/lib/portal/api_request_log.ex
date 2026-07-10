defmodule Portal.APIRequestLog do
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{
          account_id: Ecto.UUID.t(),
          log_id: String.t(),
          actor_id: Ecto.UUID.t(),
          api_token_id: Ecto.UUID.t(),
          method: String.t(),
          path: String.t(),
          content_length: integer() | nil,
          request_id: String.t(),
          user_agent: String.t() | nil,
          ip: Postgrex.INET.t(),
          ip_region: String.t() | nil,
          ip_city: String.t() | nil,
          ip_lat: float() | nil,
          ip_lon: float() | nil,
          inserted_at: DateTime.t()
        }

  @primary_key false
  @foreign_key_type :binary_id

  schema "api_request_logs" do
    belongs_to :account, Portal.Account, primary_key: true
    field :log_id, Portal.Types.LogId, primary_key: true

    field :actor_id, :binary_id
    field :api_token_id, :binary_id

    field :method, :string
    field :path, :string
    field :content_length, :integer
    field :request_id, :string

    field :user_agent, :string
    field :ip, Portal.Types.IP
    field :ip_region, :string
    field :ip_city, :string
    field :ip_lat, :float
    field :ip_lon, :float

    field :inserted_at, :utc_datetime_usec, read_after_writes: true
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required([
      :account_id,
      :log_id,
      :actor_id,
      :api_token_id,
      :method,
      :path,
      :request_id,
      :ip
    ])
    |> validate_length(:user_agent, max: 255)
    |> validate_length(:request_id, max: 255)
    |> validate_length(:ip_region, max: 255)
    |> validate_length(:ip_city, max: 255)
    |> assoc_constraint(:account)
  end
end
