defmodule FzHttp.Conf.Configuration do
  @moduledoc """
  App global configuration, singleton resource
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "configurations" do
    field :logo, :map
    field :local_auth_enabled, :boolean
    field :allow_unprivileged_device_management, :boolean
    field :openid_connect_providers, :map
    field :disable_vpn_on_oidc_error, :boolean
    field :auto_create_oidc_users, :boolean

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(configuration, attrs) do
    configuration
    |> cast(attrs, [
      :logo,
      :local_auth_enabled,
      :allow_unprivileged_device_management,
      :openid_connect_providers,
      :disable_vpn_on_oidc_error,
      :auto_create_oidc_users
    ])
  end
end
