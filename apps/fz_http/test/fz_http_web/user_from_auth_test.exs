defmodule FzHttpWeb.UserFromAuthTest do
  use FzHttp.DataCase, async: true

  alias FzHttp.Users
  alias FzHttpWeb.UserFromAuth
  alias Ueberauth.Auth

  @moduletag email: "sso@test"

  describe "find_or_create/1 via identity provider" do
    setup :create_user

    @password "password1234"

    test "sign in via identity provider", %{user: user} do
      assert {:ok, result} =
               UserFromAuth.find_or_create(%Auth{
                 provider: :identity,
                 info: %Auth.Info{email: user.email},
                 credentials: %Auth.Credentials{other: %{password: @password}}
               })

      assert result.email == user.email
    end
  end

  describe "find_or_create/2 via OIDC with auto create enabled" do
    test "sign in creates user", %{email: email} do
      FzHttp.ConfigFixtures.start_openid_providers(["google"], %{
        "auto_create_users" => true
      })

      assert {:ok, result} =
               UserFromAuth.find_or_create("google", %{
                 "email" => email,
                 "sub" => :noop
               })

      assert result.email == email
    end
  end

  describe "find_or_create/2 via OIDC with auto create disabled" do
    test "sign in returns error", %{email: email} do
      {_bypass, [openid_connect_provider_attrs]} =
        FzHttp.ConfigFixtures.start_openid_providers(["google"])

      openid_connect_provider_attrs =
        Map.put(openid_connect_provider_attrs, "auto_create_users", false)

      FzHttp.Config.put_config!(
        :openid_connect_providers,
        [openid_connect_provider_attrs]
      )

      assert {:error, "user not found and auto_create_users disabled"} =
               UserFromAuth.find_or_create(openid_connect_provider_attrs["id"], %{
                 "email" => email,
                 "sub" => :noop
               })

      assert Users.fetch_user_by_email(email) == {:error, :not_found}
    end
  end

  describe "find_or_create/2 via SAML with auto create enabled" do
    @tag config: [FzHttp.SAMLIdentityProviderFixtures.saml_attrs()]
    test "sign in creates user", %{config: config, email: email} do
      FzHttp.Config.put_config!(:saml_identity_providers, config)

      assert {:ok, result} =
               UserFromAuth.find_or_create(:saml, "test", %{"email" => email, "sub" => :noop})

      assert result.email == email
    end
  end

  describe "find_or_create/2 via SAML with auto create disabled" do
    @tag config: [
           FzHttp.SAMLIdentityProviderFixtures.saml_attrs() |> Map.put("auto_create_users", false)
         ]
    test "sign in returns error", %{email: email, config: config} do
      FzHttp.Config.put_config!(:saml_identity_providers, config)

      assert {:error, "user not found and auto_create_users disabled"} =
               UserFromAuth.find_or_create(:saml, "test", %{"email" => email, "sub" => :noop})

      assert Users.fetch_user_by_email(email) == {:error, :not_found}
    end
  end
end
