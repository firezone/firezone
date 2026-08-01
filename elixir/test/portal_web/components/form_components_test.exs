defmodule PortalWeb.FormComponentsTest.Fixture do
  use Phoenix.Component

  import PortalWeb.FormComponents

  def render(assigns) do
    ~H"""
    <.panel_footer class="test-footer">
      <.panel_footer_button id="cancel" phx-click="close_panel">
        Cancel
      </.panel_footer_button>
      <.panel_footer_button id="save" type="submit" style="primary" disabled>
        Save
      </.panel_footer_button>
      <.panel_footer_button id="back" patch="/groups">
        Back
      </.panel_footer_button>
    </.panel_footer>
    """
  end
end

defmodule PortalWeb.FormComponentsTest do
  use PortalWeb.ConnCase, async: true

  test "panel footer composes consistently sized base buttons" do
    html =
      render_component(&PortalWeb.FormComponentsTest.Fixture.render/1, %{})
      |> Floki.parse_fragment!()

    assert [footer] = Floki.find(html, ".test-footer")
    assert "py-3" in classes(footer)

    assert [cancel, save] = Floki.find(footer, "button")
    assert [back] = Floki.find(footer, "a")

    for action <- [cancel, save, back] do
      assert "text-xs" in classes(action)
      assert "px-3" in classes(action)
      assert "py-1.5" in classes(action)
    end

    assert Floki.attribute(cancel, "phx-click") == ["close_panel"]
    assert Floki.attribute(save, "disabled") == ["disabled"]
    assert Floki.attribute(back, "href") == ["/groups"]
  end

  defp classes(element) do
    element
    |> Floki.attribute("class")
    |> List.first("")
    |> String.split()
  end
end
