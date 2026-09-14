defmodule Portal.Authentication.CredentialTest do
  use ExUnit.Case, async: true

  alias Portal.Authentication.Credential

  describe "scopes/1" do
    test "an API token carries them" do
      assert Credential.scopes(%Credential.APIToken{id: id(), scopes: ["groups:read"]}) ==
               ["groups:read"]
    end

    test "no other kind does" do
      assert Credential.scopes(%Credential.ClientToken{id: id()}) == nil
      assert Credential.scopes(%Credential.PortalSession{id: id(), auth_provider_id: id()}) == nil
      assert Credential.scopes(%Credential.X509{id: id(), auth_provider_id: id()}) == nil
    end
  end

  describe "auth_provider_id/1" do
    test "an API token has none" do
      assert Credential.auth_provider_id(%Credential.APIToken{id: id(), scopes: []}) == nil
    end

    test "a client token has one only when it was signed in through one" do
      provider_id = id()

      assert Credential.auth_provider_id(%Credential.ClientToken{
               id: id(),
               auth_provider_id: provider_id
             }) == provider_id

      assert Credential.auth_provider_id(%Credential.ClientToken{id: id()}) == nil
    end

    test "a portal session and an X.509 credential always have one" do
      provider_id = id()

      assert Credential.auth_provider_id(%Credential.PortalSession{
               id: id(),
               auth_provider_id: provider_id
             }) == provider_id

      assert Credential.auth_provider_id(%Credential.X509{
               id: id(),
               auth_provider_id: provider_id
             }) == provider_id
    end
  end

  defp id, do: Ecto.UUID.generate()
end
