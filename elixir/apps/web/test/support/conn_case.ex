defmodule Web.ConnCase do
  use ExUnit.CaseTemplate
  use Domain.CaseTemplate
  import Phoenix.LiveViewTest

  using do
    quote do
      # The default endpoint for testing
      @endpoint Web.Endpoint

      use Web, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import Web.ConnCase

      import Swoosh.TestAssertions

      alias Domain.Repo
      alias Domain.Fixtures
    end
  end

  setup _tags do
    user_agent = "testing"

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("user-agent", user_agent)
      |> Plug.Test.init_test_session(%{})

    {:ok, conn: conn, user_agent: user_agent}
  end

  def flash(conn, key) do
    Phoenix.Flash.get(conn.assigns.flash, key)
  end

  def authorize_conn(conn, identity) do
    expires_in = DateTime.utc_now() |> DateTime.add(300, :second)
    {"user-agent", user_agent} = List.keyfind(conn.req_headers, "user-agent", 0, "FooBar 1.1")
    subject = Domain.Auth.build_subject(identity, expires_in, user_agent, conn.remote_ip)

    conn
    |> Web.Auth.put_subject_in_session(subject)
    |> Plug.Conn.assign(:subject, subject)
  end

  ### Helpers to test LiveView forms

  def find_inputs(html, selector) do
    html
    |> Floki.find("#{selector} input")
    |> Enum.flat_map(&Floki.attribute(&1, "name"))
    |> Enum.sort()
  end

  def find_inputs(%Phoenix.LiveViewTest.Element{} = form_element) do
    form_element |> render() |> find_inputs(form_element.selector)
  end

  def form_validation_errors(html_or_form_element) do
    html_or_form_element
    |> ensure_rendered()
    |> Floki.find("[data-validation-error-for]")
    |> Enum.map(fn html_element ->
      [field] = Floki.attribute(html_element, "data-validation-error-for")
      message = element_to_text(html_element)
      {field, message}
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp ensure_rendered(%Phoenix.LiveViewTest.Element{} = form_element), do: render(form_element)
  defp ensure_rendered(form_html), do: form_html

  @doc """
  Renders a change and allows to run assertions on it, resetting the form data afterwards.
  """
  def validate_change(form_element, attrs, callback) do
    form_html = render_change(form_element, attrs)
    callback.(form_element, form_html)
    render_change(form_element, form_element.form_data)
    form_element
  end

  ### Helpers to test LiveView tables

  def table_row_as_text_columns(row_html) do
    row_html
    |> Floki.find("td")
    |> elements_to_text()
  end

  def table_to_text(table_html) do
    table_html
    |> Floki.find("tr")
    |> Enum.map(&table_row_as_text_columns/1)
  end

  defp elements_to_text(elements) do
    Enum.map(elements, &element_to_text/1)
  end

  defp element_to_text(element) do
    element
    |> Floki.text()
    |> String.replace(~r|[\n\s ]+|, " ")
    |> String.trim()
  end
end
