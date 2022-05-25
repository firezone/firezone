defmodule FzHttpWeb.UserLive.VPNConnectionComponentTest do
  use FzHttpWeb.ConnCase, async: true

  alias FzHttp.Repo
  alias FzHttpWeb.UserLive.VPNConnectionComponent

  describe "admin" do
    setup :create_user

    test "checkbox is disabled", %{user: user} do
      assert render_component(VPNConnectionComponent, id: "1", user: user) =~ ~r"\bdisabled\b"
    end
  end

  describe "unprivileged" do
    setup :create_user

    @tag :unprivileged
    test "checkbox is not disabled", %{user: user} do
      refute render_component(VPNConnectionComponent, id: "1", user: user) =~ ~r"\bdisabled\b"
    end
  end
end
