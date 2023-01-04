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
      openid_connect_provider =
        List.first(FzHttp.ConfigurationsFixtures.openid_connect_providers_attrs())

      FzHttp.Configurations.put!(
        :openid_connect_providers,
        [openid_connect_provider]
      )

      assert {:ok, result} =
               UserFromAuth.find_or_create(openid_connect_provider["id"], %{
                 "email" => email,
                 "sub" => :noop
               })

      assert result.email == email
    end
  end

  describe "find_or_create/2 via OIDC with auto create disabled" do
    test "sign in returns error", %{email: email} do
      openid_connect_provider =
        List.first(FzHttp.ConfigurationsFixtures.openid_connect_providers_attrs())
        |> Map.put("auto_create_users", false)

      FzHttp.Configurations.put!(
        :openid_connect_providers,
        [openid_connect_provider]
      )

      assert {:error, "user not found and auto_create_users disabled"} =
               UserFromAuth.find_or_create(openid_connect_provider["id"], %{
                 "email" => email,
                 "sub" => :noop
               })

      assert Users.fetch_user_by_email(email) == {:error, :not_found}
    end
  end

  describe "find_or_create/2 via SAML with auto create enabled" do
    @tag config: [FzHttp.SAMLIdentityProviderFixtures.saml_attrs()]
    test "sign in creates user", %{config: config, email: email} do
      FzHttp.Configurations.put!(:saml_identity_providers, config)

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
      FzHttp.Configurations.put!(:saml_identity_providers, config)

      assert {:error, "user not found and auto_create_users disabled"} =
               UserFromAuth.find_or_create(:saml, "test", %{"email" => email, "sub" => :noop})

      assert Users.fetch_user_by_email(email) == {:error, :not_found}
    end
  end
end
