defmodule FzHttpWeb.UserFromAuthTest do
  use FzHttp.DataCase, async: true

  alias FzHttp.Configurations, as: Conf
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
    @tag config: %{"oidc_test" => %{auto_create_users: true}}
    test "sign in creates user", %{config: config, email: email} do
      restore_env(:openid_connect_providers, config, &on_exit/1)

      assert {:ok, result} =
               UserFromAuth.find_or_create("oidc_test", %{"email" => email, "sub" => :noop})

      assert result.email == email
    end
  end

  describe "find_or_create/2 via OIDC with auto create disabled" do
    @tag config: %{"oidc_test" => %{auto_create_users: false}}
    test "sign in returns error", %{email: email, config: config} do
      restore_env(:openid_connect_providers, config, &on_exit/1)

      assert {:error, "not found"} =
               UserFromAuth.find_or_create("oidc_test", %{"email" => email, "sub" => :noop})

      assert Users.get_by_email(email) == nil
    end
  end

  describe "find_or_create/2 via SAML with auto create enabled" do
    @tag config: %{"saml_test" => %{auto_create_users: true}}
    test "sign in creates user", %{config: config, email: email} do
      restore_env(:saml_identity_providers, config, &on_exit/1)

      assert {:ok, result} =
               UserFromAuth.find_or_create(:saml, "saml_test", %{"email" => email, "sub" => :noop})

      assert result.email == email
    end
  end

  describe "find_or_create/2 via SAML with auto create disabled" do
    @tag config: %{"saml_test" => %{auto_create_users: false}}
    test "sign in returns error", %{email: email, config: config} do
      restore_env(:saml_identity_providers, config, &on_exit/1)

      assert {:error, "not found"} =
               UserFromAuth.find_or_create(:saml, "saml_test", %{"email" => email, "sub" => :noop})

      assert Users.get_by_email(email) == nil
    end
  end
end
