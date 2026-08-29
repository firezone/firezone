defmodule Portal.OAuthClient do
  @moduledoc """
  A cached OAuth Client ID Metadata Document.

  MCP clients identify themselves with an HTTPS URL that serves their metadata,
  so there is nothing to register and no client secret to store. This table
  records what we fetched from that URL and when the copy goes stale.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Portal.Changeset, only: [trim_change: 2]

  @primary_key false
  @foreign_key_type :binary_id
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  schema "oauth_clients" do
    field :id, :binary_id, primary_key: true, autogenerate: true

    field :client_id, :string
    field :client_name, :string
    field :client_uri, :string
    field :logo_uri, :string
    field :logo_data, :binary
    field :logo_content_type, :string
    field :redirect_uris, {:array, :string}, default: []

    field :resolved_ips, {:array, Portal.Types.IP}, default: []
    field :resolved_ip_location_region, :string
    field :resolved_ip_location_city, :string

    field :metadata_expires_at, :utc_datetime_usec

    timestamps()
  end

  def changeset(%Ecto.Changeset{} = changeset) do
    changeset
    |> validate_required(~w[client_id client_name redirect_uris metadata_expires_at]a)
    |> trim_change(:client_name)
    |> validate_length(:client_name, max: 255)
    |> validate_length(:client_id, max: 2048)
    |> unique_constraint(:client_id)
  end
end
