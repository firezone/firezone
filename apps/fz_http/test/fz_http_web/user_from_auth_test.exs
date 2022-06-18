defmodule FzHttpWeb.UserFromAuthTest do
  use FzHttp.DataCase, async: true

  alias FzHttp.Users
  alias FzHttpWeb.UserFromAuth
  alias Ueberauth.Auth

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
    @email "oidc@test"

    test "sign in creates user" do
      assert {:ok, result} =
               UserFromAuth.find_or_create(:noop, %{"email" => @email, "sub" => :noop})

      assert result.email == @email
    end
  end

  describe "find_or_create/2 via OIDC with auto create disabled" do
    @email "oidc@test"

    setup do
      restore_env(:auto_create_oidc_users, false, &on_exit/1)
    end

    test "sign in returns error" do
      assert {:error, "not found"} =
               UserFromAuth.find_or_create(:noop, %{"email" => @email, "sub" => :noop})

      assert Users.get_by_email(@email) == nil
    end
  end
end
