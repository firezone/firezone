defmodule FzHttp.Configurations.Configuration do
  @moduledoc """
  App global configuration, singleton resource
  """
  use FzHttp, :schema
  import Ecto.Changeset

  alias FzHttp.{
    Configurations.Logo,
    Validator
  }

  @min_mtu 576
  @max_mtu 1500
  @min_persistent_keepalive 0
  @max_persistent_keepalive 120

  # Postgres max int size is 4 bytes
  @max_pg_integer 2_147_483_647
  @min_vpn_session_duration 0
  @max_vpn_session_duration @max_pg_integer

  schema "configurations" do
    field :allow_unprivileged_device_management, :boolean
    field :allow_unprivileged_device_configuration, :boolean

    field :local_auth_enabled, :boolean
    field :disable_vpn_on_oidc_error, :boolean

    # The defaults for these fields are set in the following migration:
    # apps/fz_http/priv/repo/migrations/20221224210654_fix_sites_nullable_fields.exs
    #
    # This will be changing in 0.8 and again when we have client apps,
    # so this works for the time being. The important thing is allowing users
    # to update these fields via the REST API since they were removed as
    # environment variables in the above migration. This is important for users
    # wishing to configure Firezone with automated Infrastructure tools like
    # Terraform.
    field :default_client_persistent_keepalive, :integer
    field :default_client_mtu, :integer
    field :default_client_endpoint, :string
    field :default_client_dns, :string
    field :default_client_allowed_ips, :string

    # XXX: Remove when this feature is refactored into config expiration feature
    # and WireGuard keys are decoupled from devices to facilitate rotation.
    #
    # See https://github.com/firezone/firezone/issues/1236
    field :vpn_session_duration, :integer, read_after_writes: true

    embeds_one :logo, Logo, on_replace: :delete

    embeds_many :openid_connect_providers,
                FzHttp.Configurations.Configuration.OpenIDConnectProvider,
                on_replace: :delete

    embeds_many :saml_identity_providers,
                FzHttp.Configurations.Configuration.SAMLIdentityProvider,
                on_replace: :delete

    timestamps()
  end

  @doc false
  def changeset(configuration, attrs) do
    configuration
    |> cast(attrs, ~w[
      local_auth_enabled
      allow_unprivileged_device_management
      allow_unprivileged_device_configuration
      disable_vpn_on_oidc_error
      default_client_persistent_keepalive
      default_client_mtu
      default_client_endpoint
      default_client_dns
      default_client_allowed_ips
      vpn_session_duration
    ]a)
    |> cast_embed(:logo)
    |> cast_embed(:openid_connect_providers,
      with: {FzHttp.Configurations.Configuration.OpenIDConnectProvider, :changeset, []}
    )
    |> cast_embed(:saml_identity_providers,
      with: {FzHttp.Configurations.Configuration.SAMLIdentityProvider, :changeset, []}
    )
    |> Validator.trim_change(:default_client_dns)
    |> Validator.trim_change(:default_client_allowed_ips)
    |> Validator.trim_change(:default_client_endpoint)
    |> Validator.validate_no_duplicates(:default_client_dns)
    |> Validator.validate_list_of_ips_or_cidrs(:default_client_allowed_ips)
    |> Validator.validate_no_duplicates(:default_client_allowed_ips)
    |> validate_number(:default_client_mtu,
      greater_than_or_equal_to: @min_mtu,
      less_than_or_equal_to: @max_mtu
    )
    |> validate_number(:default_client_persistent_keepalive,
      greater_than_or_equal_to: @min_persistent_keepalive,
      less_than_or_equal_to: @max_persistent_keepalive
    )
    |> validate_number(:vpn_session_duration,
      greater_than_or_equal_to: @min_vpn_session_duration,
      less_than_or_equal_to: @max_vpn_session_duration
    )
  end

  def max_vpn_session_duration, do: @max_vpn_session_duration
end
