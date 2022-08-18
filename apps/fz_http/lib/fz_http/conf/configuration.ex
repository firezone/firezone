defmodule FzHttp.Configurations.Configuration do
  @moduledoc """
  App global configuration, singleton resource
  """

  use Ecto.Schema
  import Ecto.Changeset
  alias FzHttp.Configurations.Logo

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "configurations" do
    embeds_one :logo, Logo, on_replace: :update
    field :local_auth_enabled, :boolean
    field :allow_unprivileged_device_management, :boolean
    field :allow_unprivileged_device_configuration, :boolean
    field :openid_connect_providers, :map
    field :saml_identity_providers, :map
    field :disable_vpn_on_oidc_error, :boolean
    field :auto_create_oidc_users, :boolean

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(configuration, attrs) do
    configuration
    |> cast(attrs, [
      :local_auth_enabled,
      :allow_unprivileged_device_management,
      :allow_unprivileged_device_configuration,
      :openid_connect_providers,
      :saml_identity_providers,
      :disable_vpn_on_oidc_error,
      :auto_create_oidc_users
    ])
    |> cast_embed(:logo)
  end
end
