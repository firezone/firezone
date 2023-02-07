defmodule FzHttp.Configurations.Configuration do
  use FzHttp, :schema
  alias FzHttp.Configurations.Logo

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
    field :default_client_dns, {:array, :string}, default: []
    field :default_client_allowed_ips, {:array, FzHttp.Types.INET}, default: []

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
end
