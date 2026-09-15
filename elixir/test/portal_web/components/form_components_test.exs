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

  describe "select" do
    test "marks the prompt selected when no value is set" do
      assert [option] = selected_options(select_html(value: nil, prompt: "Select a Site"))
      assert Floki.text(option) == "Select a Site"
    end

    test "marks the matching option selected instead of the prompt" do
      assert [option] = selected_options(select_html(value: "b", prompt: "Select a Site"))
      assert Floki.attribute(option, "value") == ["b"]
    end

    test "marks the prompt selected when the value matches no option" do
      assert [option] = selected_options(select_html(value: "missing", prompt: "Select a Site"))
      assert Floki.text(option) == "Select a Site"
    end

    test "marks the first option selected when there is no prompt and no value" do
      assert [option] = selected_options(select_html(value: nil))
      assert Floki.attribute(option, "value") == ["a"]
    end

    test "marks the matching option selected when there is no prompt" do
      assert [option] = selected_options(select_html(value: "b"))
      assert Floki.attribute(option, "value") == ["b"]
    end

    test "keeps every chosen option selected for a multiple select" do
      html = select_html(value: ["a", "b"], multiple: true)
      assert ["a", "b"] = html |> selected_options() |> Floki.attribute("value")
    end

    test "marks the prompt of a group select selected when no value is set" do
      html =
        select_html(
          type: "group_select",
          value: nil,
          prompt: "Select a Site",
          options: [{"Group", [{"A", "a"}, {"B", "b"}]}]
        )

      assert [option] = selected_options(html)
      assert Floki.text(option) == "Select a Site"
    end

    test "keeps a nil-valued first option of a group select selected when no value is set" do
      html =
        select_html(
          type: "group_select",
          value: nil,
          options: [{nil, [{"For any Site", nil}]}, {"Sites", [{"A", "a"}, {"B", "b"}]}]
        )

      assert [option] = selected_options(html)
      assert Floki.text(option) == "For any Site"
    end

    test "marks the first grouped option selected when there is no prompt and no value" do
      html =
        select_html(type: "group_select", value: nil, options: [{"Group", [{"A", "a"}, {"B", "b"}]}])

      assert [option] = selected_options(html)
      assert Floki.attribute(option, "value") == ["a"]
    end
  end

  defp select_html(opts) do
    {value, opts} = Keyword.pop(opts, :value)
    form = Phoenix.Component.to_form(%{"site_id" => value}, as: :resource)

    assigns =
      Enum.into(opts, %{
        field: form[:site_id],
        type: "select",
        options: [{"A", "a"}, {"B", "b"}]
      })

    render_component(&PortalWeb.FormComponents.input/1, assigns)
  end

  defp selected_options(html) do
    html |> Floki.parse_fragment!() |> Floki.find("option[selected]")
  end

  defp classes(element) do
    element
    |> Floki.attribute("class")
    |> List.first("")
    |> String.split()
  end
end
