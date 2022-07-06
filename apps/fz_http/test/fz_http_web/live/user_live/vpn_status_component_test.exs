defmodule FzHttpWeb.UserLive.VPNStatusComponentTest do
  use FzHttpWeb.ConnCase, async: true

  alias FzHttpWeb.UserLive.VPNStatusComponent

  describe "admin" do
    setup :create_user

    test "enabled tag", %{user: user} do
      test_component =
        render_component(VPNStatusComponent, %{
          id: "1",
          user: user,
          vpn_expired: false
        })

      assert test_component =~ ~r"\bENABLED\b"
    end

    test "disabled tag", %{user: user} do
      test_component =
        render_component(VPNStatusComponent, %{
          id: "1",
          user: Map.put(user, :disabled_at, DateTime.utc_now()),
          vpn_expired: false
        })

      assert test_component =~ ~r"\bDISABLED\b"
    end

    test "expired tag user signed in", %{user: user} do
      test_component =
        render_component(VPNStatusComponent, %{
          id: "1",
          user: Map.put(user, :last_signed_in_at, DateTime.utc_now()),
          vpn_expired: true
        })

      assert test_component =~ ~r"\bEXPIRED\b"

      assert test_component =~
               ~r"\bThis user's VPN connection is disabled due to authentication expiration\b"
    end

    test "expired tag user signed out", %{user: user} do
      test_component =
        render_component(VPNStatusComponent, %{
          id: "1",
          user: user,
          vpn_expired: true
        })

      assert test_component =~ ~r"\bEXPIRED\b"
      assert test_component =~ ~r"\bUser must sign in to activate\b"
    end
  end
end
