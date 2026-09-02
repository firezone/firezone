defmodule PortalAPI.Scopes do
  @moduledoc """
  Maps each API controller to the entity its operations are scoped by.

  Keyed on the controller rather than the request path so that a route can be
  renamed or nested differently without silently changing what a credential
  needs to reach it.

  Minting a credential is granted apart from reading the thing it belongs to:
  a client token lets a device sign in as its actor, and a gateway token lets a
  gateway join a site, so neither follows from being allowed to list clients or
  gateways.

  A controller that is not mapped is refused, so adding a route without
  deciding what it is scoped by cannot quietly widen every existing
  credential.
  """

  @entity_by_controller %{
    PortalAPI.AccountController => :account,
    PortalAPI.ActorController => :actors,
    PortalAPI.GroupController => :groups,
    PortalAPI.MembershipController => :groups,
    PortalAPI.ExternalIdentityController => :external_identities,
    PortalAPI.ClientController => :clients,
    PortalAPI.ClientTokenController => :client_tokens,
    PortalAPI.SiteController => :sites,
    PortalAPI.GatewayController => :gateways,
    PortalAPI.GatewayTokenController => :gateway_tokens,
    PortalAPI.ResourceController => :resources,
    PortalAPI.PoolMemberController => :resources,
    PortalAPI.PolicyController => :policies,
    PortalAPI.LogController => :logs,
    PortalAPI.EmailOTPAuthProviderController => :auth_providers,
    PortalAPI.X509AuthProviderController => :auth_providers,
    PortalAPI.OIDCAuthProviderController => :auth_providers,
    PortalAPI.GoogleAuthProviderController => :auth_providers,
    PortalAPI.EntraAuthProviderController => :auth_providers,
    PortalAPI.OktaAuthProviderController => :auth_providers,
    PortalAPI.GoogleDirectoryController => :directories,
    PortalAPI.EntraDirectoryController => :directories,
    PortalAPI.OktaDirectoryController => :directories,
    PortalAPI.IntuneDeviceController => :posture_providers,
    PortalAPI.IruDeviceController => :posture_providers,
    PortalAPI.DefenderDeviceController => :posture_providers,
    PortalAPI.SantaDeviceController => :posture_providers,
    PortalAPI.SentinelOneDeviceController => :posture_providers,
    PortalAPI.IntunePostureProviderController => :posture_providers,
    PortalAPI.IruPostureProviderController => :posture_providers,
    PortalAPI.DefenderPostureProviderController => :posture_providers,
    PortalAPI.SantaPostureProviderController => :posture_providers,
    PortalAPI.SentinelOnePostureProviderController => :posture_providers
  }

  @doc "The entity `controller` operates on, or `:error` if it is not mapped."
  def entity_for(controller), do: Map.fetch(@entity_by_controller, controller)

  @doc "Every controller that carries an entity."
  def controllers, do: Map.keys(@entity_by_controller)
end
