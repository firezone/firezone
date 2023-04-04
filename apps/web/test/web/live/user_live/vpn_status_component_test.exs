defmodule Web.UserLive.VPNStatusComponentTest do
  use Web.ConnCase, async: true

  alias Web.UserLive.VPNStatusComponent

  describe "admin" do
    setup :create_user

    test "enabled tag", %{user: user} do
      test_component =
        render_component(&VPNStatusComponent.status/1, %{
          user: user,
          expired: false
        })

      assert test_component =~ ~r"\bENABLED\b"
    end

    test "disabled tag", %{user: user} do
      test_component =
        render_component(&VPNStatusComponent.status/1, %{
          user: Map.put(user, :disabled_at, DateTime.utc_now()),
          expired: false
        })

      assert test_component =~ ~r"\bDISABLED\b"
    end

    test "expired tag user signed in", %{user: user} do
      test_component =
        render_component(&VPNStatusComponent.status/1, %{
          user: Map.put(user, :last_signed_in_at, DateTime.utc_now()),
          expired: true
        })

      assert test_component =~ ~r"\bEXPIRED\b"

      assert test_component =~
               ~r"\bThis user's VPN connection is disabled due to authentication expiration\b"
    end

    test "expired tag user signed out", %{user: user} do
      test_component =
        render_component(&VPNStatusComponent.status/1, %{
          user: user,
          expired: true
        })

      assert test_component =~ ~r"\bEXPIRED\b"
      assert test_component =~ ~r"\bUser must sign in to activate\b"
    end
  end
end
