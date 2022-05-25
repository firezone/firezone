defmodule FzHttpWeb.UserLive.VPNConnectionComponentTest do
  use FzHttpWeb.ConnCase, async: true

  alias FzHttp.Repo
  alias FzHttpWeb.UserLive.VPNConnectionComponent

  describe "admin" do
    setup :create_user

    test "checkbox is disabled", %{user: user} do
      assert render_component(VPNConnectionComponent, id: "1", user: user) =~ "disabled"
    end
  end

  describe "unprivileged" do
    setup :create_user

    @tag :unprivileged
    test "checkbox is not disabled", %{user: user} do
      refute render_component(VPNConnectionComponent, id: "1", user: user) =~ "disabled"
    end

    @tag :unprivileged
    test "handle_event toggle_disabled_at on", %{user: user} do
      VPNConnectionComponent.handle_event("toggle_disabled_at", %{"value" => "on"}, %{
        assigns: %{user: user}
      })

      user = Repo.reload(user)

      refute user.disabled_at
    end

    @tag :unprivileged
    test "handle_event toggle_disabled_at off", %{user: user} do
      VPNConnectionComponent.handle_event("toggle_disabled_at", %{}, %{assigns: %{user: user}})

      user = Repo.reload(user)

      assert user.disabled_at
    end
  end
end
