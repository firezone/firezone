defmodule PortalWeb.Components.FormTest.Fixture do
  use Phoenix.Component

  alias PortalWeb.Components.Form

  def render(assigns) do
    ~H"""
    <Form.panel_footer class="test-footer">
      <Form.panel_footer_button id="cancel" phx-click="close_panel">
        Cancel
      </Form.panel_footer_button>
      <Form.panel_footer_button id="save" type="submit" style="primary" disabled>
        Save
      </Form.panel_footer_button>
      <Form.panel_footer_button id="back" patch="/groups">
        Back
      </Form.panel_footer_button>
    </Form.panel_footer>
    """
  end
end

defmodule PortalWeb.Components.FormTest do
  use PortalWeb.ConnCase, async: true

  alias Portal.APIToken
  alias Portal.Splunk
  alias PortalWeb.Components.Form

  test "panel footer composes consistently sized base buttons" do
    html =
      render_component(&PortalWeb.Components.FormTest.Fixture.render/1, %{})
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

  describe "password input" do
    test "never renders a redacted field's stored value" do
      html = password_html(:hec_token, %Splunk.LogSink{hec_token: "stored-secret"})

      refute html =~ "stored-secret"
      assert html =~ "Leave blank to keep the current value"
    end

    test "echoes only what the browser submitted for a redacted field" do
      html =
        password_html(:hec_token, %Splunk.LogSink{hec_token: "stored-secret"}, %{"hec_token" => "typed"})

      refute html =~ "stored-secret"
      assert html =~ ~s(value="typed")
    end

    test "fails when the schema field is not redacted, naming only the field" do
      # Splunk's index isn't a secret; it only stands in for a field someone
      # forgot to redact.
      error =
        assert_raise MatchError, fn ->
          password_html(:index, %Splunk.LogSink{index: "stored-value"})
        end

      assert error.term == {Splunk.LogSink, :index, false}
      refute Exception.message(error) =~ "stored-value"
    end

    test "drops required and offers to keep a stored secret" do
      input = password_input(:hec_token, Ecto.Changeset.change(%Splunk.LogSink{hec_token: "stored-secret"}))

      assert Floki.attribute(input, "required") == []
      assert Floki.attribute(input, "placeholder") == ["Leave blank to keep the current value"]
    end

    test "keeps a reset secret required" do
      changeset =
        %Splunk.LogSink{hec_token: "stored-secret"}
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.put_change(:hec_token, nil)

      input = password_input(:hec_token, changeset)

      assert Floki.attribute(input, "required") == ["required"]
      assert Floki.attribute(input, "placeholder") == []
    end

    test "keeps a typed virtual field required" do
      # A virtual, redacted field like a password confirmation never has a
      # saved value, however much is typed into it.
      changeset = Ecto.Changeset.cast(%APIToken{}, %{"secret_fragment" => "typed"}, [:secret_fragment])

      input = password_input(:secret_fragment, changeset)

      assert Floki.attribute(input, "required") == ["required"]
      assert Floki.attribute(input, "placeholder") == []
      assert Floki.attribute(input, "value") == ["typed"]
    end

    test "renders a password input on a form without a schema" do
      form = Phoenix.Component.to_form(%{"password" => "typed"}, as: :login)

      html = render_component(&Form.input/1, %{field: form[:password], type: "password"})

      assert html =~ ~s(value="typed")
    end
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

    render_component(&PortalWeb.Components.Form.input/1, assigns)
  end

  defp selected_options(html) do
    html |> Floki.parse_fragment!() |> Floki.find("option[selected]")
  end

  defp password_html(field, data, params \\ %{}) do
    form =
      data
      |> Ecto.Changeset.cast(params, [:hec_token, :index])
      |> Phoenix.Component.to_form(as: :credentials)

    render_component(&Form.input/1, %{field: form[field], type: "password"})
  end

  defp password_input(field, changeset) do
    form = Phoenix.Component.to_form(changeset, as: :credentials)

    render_component(&Form.input/1, %{field: form[field], type: "password", required: true})
    |> Floki.parse_fragment!()
    |> Floki.find("input[type=password]")
  end

  defp classes(element) do
    element
    |> Floki.attribute("class")
    |> List.first("")
    |> String.split()
  end
end
