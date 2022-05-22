defmodule FzHttpWeb.UserLive.AllowedToConnectComponentTest do
  use FzHttpWeb.ConnCase, async: true

  alias FzHttpWeb.UserLive.AllowedToConnectComponent

  describe "admin" do
    setup :create_user

    test "checkbox is disabled", %{user: user} do
      assert render_component(AllowedToConnectComponent, id: "1", user: user) =~ "disabled"
    end
  end

  describe "unprivileged" do
    setup :create_user

    @tag :unprivileged
    test "checkbox is not disabled", %{user: user} do
      refute render_component(AllowedToConnectComponent, id: "1", user: user) =~ "disabled"
    end
  end
end
