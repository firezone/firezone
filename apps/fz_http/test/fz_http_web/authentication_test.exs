defmodule FzHttpWeb.AuthTest do
  use FzHttpWeb.ConnCase, async: true

  alias FzHttpWeb.Auth.WWW.Authentication

  describe "authenticate/2" do
    setup :create_user

    @success {:ok, %{}}
    @error {:error, :invalid_credentials}

    test "authenticates user with valid credentials", %{user: user} do
      assert @success = Authentication.authenticate(user, "password1234")
    end

    test "returns error for missing user" do
      assert @error = Authentication.authenticate(nil, "password1234")
    end

    test "returns error for missing password", %{user: user} do
      assert @error = Authentication.authenticate(user, nil)
    end

    test "returns error for incorrect password", %{user: user} do
      assert @error = Authentication.authenticate(user, "incorrect password")
    end
  end
end
