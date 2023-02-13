defmodule FzHttp.AuthTest do
  use FzHttp.DataCase
  import FzHttp.Auth
  alias FzHttp.ConfigFixtures
  alias FzHttp.SAMLIdentityProviderFixtures

  describe "fetch_oidc_provider_config/1" do
  end

  describe "auto_create_users?/2" do
    test "raises if provider_id not found" do
      assert_raise(RuntimeError, "Unknown provider foobar", fn ->
        auto_create_users?(:openid_connect_providers, "foobar")
      end)
    end

    test "returns true for found provider_id" do
      ConfigFixtures.configuration(%{
        saml_identity_providers: [
          %{
            "id" => "test",
            "metadata" => SAMLIdentityProviderFixtures.metadata(),
            "auto_create_users" => true,
            "label" => "SAML"
          }
        ]
      })

      assert auto_create_users?(:saml_identity_providers, "test")
    end

    test "returns false for found provider_id" do
      ConfigFixtures.configuration(%{
        saml_identity_providers: [
          %{
            "id" => "test",
            "metadata" => SAMLIdentityProviderFixtures.metadata(),
            "auto_create_users" => false,
            "label" => "SAML"
          }
        ]
      })

      refute auto_create_users?(:saml_identity_providers, "test")
    end
  end
end
