defmodule Domain.AuthTest do
  use Domain.DataCase
  import Domain.Auth
  alias Domain.ConfigFixtures

  describe "fetch_oidc_provider_config/1" do
    test "returns error when provider does not exist" do
      assert fetch_oidc_provider_config(Ecto.UUID.generate()) == {:error, :not_found}
      assert fetch_oidc_provider_config("foo") == {:error, :not_found}
    end

    test "returns openid connect provider" do
      {_bypass, [attrs]} = ConfigFixtures.start_openid_providers(["google"])

      assert fetch_oidc_provider_config(attrs["id"]) ==
               {:ok,
                %{
                  client_id: attrs["client_id"],
                  client_secret: attrs["client_secret"],
                  discovery_document_uri: attrs["discovery_document_uri"],
                  redirect_uri: attrs["redirect_uri"],
                  response_type: attrs["response_type"],
                  scope: attrs["scope"]
                }}
    end

    test "puts default redirect_uri" do
      Domain.Config.put_env_override(:web, :external_url, "http://foo.bar.com/")

      {_bypass, [attrs]} =
        ConfigFixtures.start_openid_providers(["google"], %{"redirect_uri" => nil})

      assert fetch_oidc_provider_config(attrs["id"]) ==
               {:ok,
                %{
                  client_id: attrs["client_id"],
                  client_secret: attrs["client_secret"],
                  discovery_document_uri: attrs["discovery_document_uri"],
                  redirect_uri: "http://foo.bar.com/auth/oidc/google/callback/",
                  response_type: attrs["response_type"],
                  scope: attrs["scope"]
                }}
    end
  end

  describe "auto_create_users?/2" do
    test "raises if provider_id not found" do
      assert_raise(RuntimeError, "Unknown provider foobar", fn ->
        auto_create_users?(:openid_connect_providers, "foobar")
      end)
    end

    test "returns true if auto_create_users is true" do
      ConfigFixtures.configuration(%{
        saml_identity_providers: [
          %{
            "id" => "test",
            "metadata" => ConfigFixtures.saml_metadata(),
            "auto_create_users" => true,
            "label" => "SAML"
          }
        ]
      })

      assert auto_create_users?(:saml_identity_providers, "test")
    end

    test "returns false if auto_create_users is false" do
      ConfigFixtures.configuration(%{
        saml_identity_providers: [
          %{
            "id" => "test",
            "metadata" => ConfigFixtures.saml_metadata(),
            "auto_create_users" => false,
            "label" => "SAML"
          }
        ]
      })

      refute auto_create_users?(:saml_identity_providers, "test")
    end
  end
end
