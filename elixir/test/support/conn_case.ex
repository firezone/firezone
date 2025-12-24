defmodule PortalWeb.ConnCase do
  use ExUnit.CaseTemplate
  use Portal.CaseTemplate
  use PortalWeb, :verified_routes
  import Phoenix.LiveViewTest
  import Phoenix.ConnTest
  import Portal.TokenFixtures

  using do
    quote do
      # The default endpoint for testing
      @endpoint PortalWeb.Endpoint

      use PortalWeb, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import PortalWeb.ConnCase

      import Swoosh.TestAssertions

      alias Portal.Repo
      alias Portal.Fixtures
      alias Portal.Mocks
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

    conn = %{conn | secret_key_base: PortalWeb.Endpoint.config(:secret_key_base)}

    {:ok, conn: conn, user_agent: user_agent}
  end

  def assert_lists_equal(list1, list2) do
    assert Enum.sort(list1) == Enum.sort(list2)
  end

  def equal_ids?(list1, list2) do
    MapSet.equal?(MapSet.new(list1), MapSet.new(list2))
  end

  def flash(conn, key) do
    Phoenix.Flash.get(conn.assigns.flash, key)
  end

  def authorize_conn(conn, %Portal.Actor{} = actor) do
    {"user-agent", user_agent} = List.keyfind(conn.req_headers, "user-agent", 0, "FooBar 1.1")

    context = %Portal.Auth.Context{
      type: :portal,
      user_agent: user_agent,
      remote_ip_location_region: "UA",
      remote_ip_location_city: "Kyiv",
      remote_ip_location_lat: 50.4501,
      remote_ip_location_lon: 30.5234,
      remote_ip: conn.remote_ip
    }

    # Fetch the real account from the database
    account = Portal.Repo.get!(Portal.Account, actor.account_id)

    # Create an auth provider for this account if needed
    auth_provider = Portal.AuthProviderFixtures.email_otp_provider_fixture(account: account)

    expires_at = DateTime.add(DateTime.utc_now(), 300, :second)

    {:ok, session} =
      Portal.Auth.create_portal_session(
        actor,
        auth_provider.id,
        context,
        expires_at
      )

    {:ok, subject} = Portal.Auth.build_subject(session, context)

    # Set the cookie. We need to set it as a response cookie first,
    # then transfer to request cookies for subsequent requests.
    cookie = %PortalWeb.Cookie.Session{session_id: session.id}
    conn = PortalWeb.Cookie.Session.put(conn, actor.account_id, cookie)
    cookie_name = "sess_#{actor.account_id}"
    cookie_value = conn.resp_cookies[cookie_name].value

    conn
    |> put_req_cookie(cookie_name, cookie_value)
    |> Plug.Conn.assign(:account, subject.account)
    |> Plug.Conn.assign(:subject, subject)
  end

  def authorize_api_conn(conn, %Portal.Actor{account: account} = actor) do
    expires_at = DateTime.utc_now() |> DateTime.add(300, :second)
    api_token = api_token_fixture(actor: actor, account: account, expires_at: expires_at)
    encoded_fragment = encode_api_token(api_token)

    Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> encoded_fragment)
  end

  def put_email_auth_state(
        conn,
        account,
        %{adapter: :email} = provider,
        identity,
        params \\ %{}
      ) do
    params =
      Map.merge(%{"email" => %{"provider_identifier" => identity.provider_identifier}}, params)

    redirected_conn =
      post(conn, ~p"/#{account}/sign_in/providers/#{provider.id}/request_email_otp", params)

    assert_received {:email, email}
    [_match, secret] = Regex.run(~r/secret=([^&\n]*)/, email.text_body)

    cookie_key = "fz_auth_state_#{provider.id}"
    %{value: signed_state} = redirected_conn.resp_cookies[cookie_key]

    conn_with_cookie = put_req_cookie(conn, "fz_auth_state_#{provider.id}", signed_state)

    {conn_with_cookie, secret}
  end

  def put_idp_auth_state(conn, account, provider, params \\ %{}) do
    redirected_conn =
      get(conn, ~p"/#{account.id}/sign_in/providers/#{provider.id}/redirect", params)

    cookie_key = "fz_auth_state_#{provider.id}"
    redirected_conn = Plug.Conn.fetch_cookies(redirected_conn, signed: [cookie_key])

    {_params, state, verifier} =
      redirected_conn.cookies[cookie_key]
      |> :erlang.binary_to_term([:safe])

    %{value: signed_state} = redirected_conn.resp_cookies[cookie_key]

    conn_with_cookie = put_req_cookie(conn, "fz_auth_state_#{provider.id}", signed_state)

    {conn_with_cookie, state, verifier}
  end

  def put_client_auth_state(
        conn,
        account,
        %{adapter: :email} = provider,
        identity,
        params \\ %{}
      ) do
    params =
      Map.merge(
        %{
          "email" => %{"provider_identifier" => identity.provider_identifier},
          "as" => "client",
          "nonce" => "nonce",
          "state" => "state"
        },
        params
      )

    redirected_conn =
      post(conn, ~p"/#{account}/sign_in/providers/#{provider.id}/request_email_otp", params)

    assert_received {:email, email}
    [_match, secret] = Regex.run(~r/secret=([^&\n]*)/, email.text_body)

    auth_state_cookie_key = "fz_auth_state_#{provider.id}"
    %{value: signed_state} = redirected_conn.resp_cookies[auth_state_cookie_key]

    verified_conn =
      conn
      |> put_req_cookie("fz_auth_state_#{provider.id}", signed_state)
      |> get(~p"/#{account}/sign_in/providers/#{provider}/verify_sign_in_token", %{
        "identity_id" => identity.id,
        "secret" => secret
      })

    client_cookie_key = "fz_client_auth"
    %{value: signed_client_auth} = verified_conn.resp_cookies[client_cookie_key]

    conn
    |> put_req_cookie("fz_client_auth", signed_client_auth)
    |> put_req_cookie("fz_auth_state_#{provider.id}", signed_state)
  end

  ### Helpers to test LiveView forms

  # Helper to parse HTML if it's a string, or return as-is if already parsed
  defp parse_if_needed(html) when is_binary(html), do: Floki.parse_fragment!(html)
  defp parse_if_needed(parsed), do: parsed

  def find_inputs(html, selector) do
    html
    |> parse_if_needed()
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
    |> parse_if_needed()
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
    if string =~ "Now" do
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
    |> parse_if_needed()
    |> Floki.find("tbody tr")
    |> Enum.map(fn row ->
      key = row |> Floki.find("th") |> reject_tooltips() |> element_to_text() |> String.downcase()
      value = row |> Floki.find("td") |> element_to_text()
      {key, value}
    end)
    |> Enum.into(%{})
  end

  def table_columns(table_html) do
    table_html
    |> parse_if_needed()
    |> Floki.find("thead tr th")
    |> elements_to_text()
    |> Enum.map(&String.downcase/1)
  end

  def table_rows(table_html) do
    table_html
    |> parse_if_needed()
    |> Floki.find("tbody tr")
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

  defp reject_tooltips([{"th", attrs, content}]) do
    content =
      content
      |> Enum.reject(fn
        {"div", attrs, _content} ->
          {"role", "tooltip"} in attrs

        _ ->
          false
      end)

    [{"th", attrs, content}]
  end

  defp reject_tooltips(other) do
    other
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

  def active_buttons(html) do
    html
    |> parse_if_needed()
    |> Floki.find("main button")
    |> Enum.filter(fn button ->
      Floki.attribute(button, "disabled") != "disabled"
    end)
    |> elements_to_text()
    |> Enum.reject(&(&1 in ["", "Previous", "Next", "Clear filters", "CopyCopied"]))
  end

  ## Wait helpers

  @doc """
  Waits for an ExUnit assertion to be `true` before timing out.

  This is helpful when we check UI state changes in LiveView tests,
  where we don't know if the view was updated before or after the test.

  Default wait time is 2 seconds.
  """
  def wait_for(assertion_callback, wait_seconds \\ 2, started_at \\ nil) do
    now = :erlang.monotonic_time(:milli_seconds)
    started_at = started_at || now

    try do
      assertion_callback.()
    rescue
      e in [ExUnit.AssertionError] ->
        time_spent = now - started_at

        if time_spent > :timer.seconds(wait_seconds) do
          reraise(e, __STACKTRACE__)
        else
          floor(time_spent / 10)
          |> max(100)
          |> :timer.sleep()

          wait_for(assertion_callback, wait_seconds, started_at)
        end
    end
  end
end
