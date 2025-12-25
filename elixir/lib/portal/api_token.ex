defmodule Portal.APIToken do
  use Ecto.Schema
  import Ecto.Changeset
  import Portal.Changeset

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  schema "api_tokens" do
    belongs_to :account, Portal.Account, primary_key: true
    field :id, :binary_id, primary_key: true, autogenerate: true

    belongs_to :actor, Portal.Actor

    field :name, :string

    field :secret_hash, :string, redact: true
    field :secret_salt, :string, redact: true

    # Used only during creation
    field :secret_fragment, :string, virtual: true, redact: true

    field :last_seen_user_agent, :string
    field :last_seen_remote_ip, Portal.Types.IP
    field :last_seen_remote_ip_location_region, :string
    field :last_seen_remote_ip_location_city, :string
    field :last_seen_remote_ip_location_lat, :float
    field :last_seen_remote_ip_location_lon, :float
    field :last_seen_at, :utc_datetime_usec

    field :expires_at, :utc_datetime_usec

    timestamps()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_length(:name, max: 255)
    |> trim_change(:name)
    |> assoc_constraint(:account)
    |> assoc_constraint(:actor)
  end
end
