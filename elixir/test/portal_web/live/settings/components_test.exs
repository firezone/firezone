defmodule PortalWeb.Settings.ComponentsTest do
  use PortalWeb.ConnCase, async: true

  alias PortalWeb.Settings.Components

  describe "skeleton/1" do
    test "renders the requested number of placeholder rows hidden from assistive tech" do
      html = render_component(&Components.skeleton/1, id: "things-skeleton", rows: 3, class: "max-w-2xl")
      [skeleton] = html |> Floki.parse_fragment!() |> Floki.find("#things-skeleton")

      assert Floki.attribute(skeleton, "aria-hidden") == ["true"]
      assert [classes] = Floki.attribute(skeleton, "class")
      assert classes =~ "animate-pulse"
      assert classes =~ "max-w-2xl"
      assert length(Floki.children(skeleton)) == 3
    end
  end
end
