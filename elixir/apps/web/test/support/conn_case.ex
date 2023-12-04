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
      alias Domain.Mocks
    end
  end

  setup _tags do
    user_agent = "testing"

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("user-agent", user_agent)
      |> Plug.Test.init_test_session(%{})
      |> Plug.Conn.put_req_header("x-geo-location-region", "UA")
      |> Plug.Conn.put_req_header("x-geo-location-city", "Kyiv")
      |> Plug.Conn.put_req_header("x-geo-location-coordinates", "50.4333,30.5167")

    {:ok, conn: conn, user_agent: user_agent}
  end

  def assert_lists_equal(list1, list2) do
    assert Enum.sort(list1) == Enum.sort(list2)
  end

  def flash(conn, key) do
    Phoenix.Flash.get(conn.assigns.flash, key)
  end

  def authorize_conn(conn, %Domain.Auth.Identity{} = identity) do
    expires_in = DateTime.utc_now() |> DateTime.add(300, :second)
    {"user-agent", user_agent} = List.keyfind(conn.req_headers, "user-agent", 0, "FooBar 1.1")

    context = %Domain.Auth.Context{
      user_agent: user_agent,
      remote_ip_location_region: "UA",
      remote_ip_location_city: "Kyiv",
      remote_ip_location_lat: 50.4501,
      remote_ip_location_lon: 30.5234,
      remote_ip: conn.remote_ip
    }

    subject = Domain.Auth.build_subject(identity, expires_in, context)

    conn
    |> Web.Auth.put_subject_in_session(subject)
    |> Plug.Conn.assign(:account, subject.account)
    |> Plug.Conn.assign(:subject, subject)
  end

  ### Helpers to test LiveView forms

  def find_inputs(html, selector) do
    html
    |> Floki.find("#{selector} input,select,textarea")
    |> Enum.flat_map(&Floki.attribute(&1, "name"))
    |> Enum.uniq()
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

  ### Helpers to test formatted time units

  def around_now?(string) do
    if string =~ "now" do
      true
    else
      [_all, seconds] = Regex.run(~r/([0-9]+) second[s]? ago/, string)
      seconds = String.to_integer(seconds)
      assert seconds in 0..5
    end
  end

  ### Helpers to test LiveView tables

  def table_to_map(table_html) do
    columns = table_columns(table_html)
    rows = table_rows(table_html)

    for row <- rows do
      Enum.zip(columns, row)
      |> Enum.into(%{})
    end
  end

  def vertical_table_to_map(table_html) do
    table_html
    |> Floki.find("tbody tr")
    |> Enum.map(fn row ->
      key = Floki.find(row, "th") |> element_to_text() |> String.downcase()
      value = Floki.find(row, "td") |> element_to_text()
      {key, value}
    end)
    |> Enum.into(%{})
  end

  def table_columns(table_html) do
    Floki.find(table_html, "thead tr th")
    |> elements_to_text()
    |> Enum.map(&String.downcase/1)
  end

  def table_rows(table_html) do
    Floki.find(table_html, "tbody tr")
    |> Enum.map(fn row ->
      row
      |> Floki.find("td")
      |> elements_to_text()
    end)
  end

  def with_table_row(rows, key, value, callback) do
    row = Enum.find(rows, fn row -> Map.get(row, key) == value end)
    assert row, "No row found with #{key} = #{value} in #{inspect(rows)}"
    callback.(row)
    rows
  end

  def elements_to_text(elements) do
    Enum.map(elements, &element_to_text/1)
  end

  def element_to_text(element) do
    element
    |> Floki.text()
    |> String.replace(~r|[\n\s ]+|, " ")
    |> String.trim()
  end
end
