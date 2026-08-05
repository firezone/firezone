defmodule Portal.Safe.FirezoneSupportPermitTest do
  use ExUnit.Case, async: true

  alias Portal.Safe

  test "reads delegate to account admin permissions" do
    assert Safe.permit(:read, Portal.Actor, :firezone_support) == :ok
    assert Safe.permit(:read, Portal.APIToken, :firezone_support) == :ok
    assert Safe.permit(:read, Portal.OIDC.AuthProvider, :firezone_support) == :ok
    assert Safe.permit(:read, Portal.ChangeLog, :firezone_support) == :ok
    assert Safe.permit(:read, Portal.Account, :firezone_support) == :ok
  end

  test "writes to credential and auth surfaces are denied" do
    denied = [
      Portal.Account,
      Portal.Actor,
      Portal.ExternalIdentity,
      Portal.APIToken,
      Portal.ClientToken,
      Portal.GatewayToken,
      Portal.AuthProvider,
      Portal.Google.AuthProvider,
      Portal.Okta.AuthProvider,
      Portal.Entra.AuthProvider,
      Portal.OIDC.AuthProvider,
      Portal.EmailOTP.AuthProvider,
      Portal.Userpass.AuthProvider,
      Portal.FirezoneSupport.AuthProvider,
      Portal.Entra.Directory,
      Portal.Google.Directory,
      Portal.Okta.Directory,
      Portal.TrustAnchor
    ]

    for schema <- denied, action <- [:insert, :update, :delete, :delete_all] do
      assert Safe.permit(action, schema, :firezone_support) == {:error, :unauthorized},
             "expected #{inspect(action)} on #{inspect(schema)} to be denied"
    end
  end

  test "configuration writes remain allowed" do
    for schema <- [
          Portal.Policy,
          Portal.Resource,
          Portal.Site,
          Portal.Group,
          Portal.Membership,
          Portal.Device
        ] do
      assert Safe.permit(:insert, schema, :firezone_support) == :ok,
             "expected insert on #{inspect(schema)} to be allowed"
    end
  end

  test "the support whitelist itself stays unreachable" do
    assert Safe.permit(:read, Portal.SupportAdmin, :firezone_support) == {:error, :unauthorized}
    assert Safe.permit(:insert, Portal.SupportAdmin, :firezone_support) == {:error, :unauthorized}
  end
end
