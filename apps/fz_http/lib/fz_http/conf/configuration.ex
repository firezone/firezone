defmodule FzHttp.Configurations.Configuration do
  @moduledoc """
  App global configuration, singleton resource
  """
  use FzHttp, :schema
  import Ecto.Changeset
  alias FzHttp.Configurations.Logo

  schema "configurations" do
    field :allow_unprivileged_device_management, :boolean
    field :allow_unprivileged_device_configuration, :boolean

    field :local_auth_enabled, :boolean
    field :openid_connect_providers, :map
    field :saml_identity_providers, :map
    field :disable_vpn_on_oidc_error, :boolean

    embeds_one :logo, Logo, on_replace: :update

    timestamps()
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
      :disable_vpn_on_oidc_error
    ])
    |> cast_embed(:logo)
  end
end
