defmodule PortalWeb.ConnCase do
  use ExUnit.CaseTemplate
  use Portal.CaseTemplate
  use PortalWeb, :verified_routes
  import Phoenix.LiveViewTest
  import Phoenix.ConnTest

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
      import Portal.Test.Assertions

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

  @doc """
  Sets up socket assigns for URI-based navigation, simulating what
  the SetCurrentUri hook does during handle_params.
  """
  def put_uri_assigns(socket, uri) do
    parsed = URI.parse(uri)

    query_params =
      if parsed.query do
        URI.decode_query(parsed.query)
      else
        %{}
      end

    Phoenix.Component.assign(socket,
      current_path: parsed.path,
      query_params: query_params
    )
  end

  def flash(conn, key) do
    Phoenix.Flash.get(conn.assigns.flash, key)
  end

  def authorize_conn(conn, %Portal.Actor{} = actor) do
    # Fetch the real account from the database
    account = Portal.Repo.get!(Portal.Account, actor.account_id)

    # Create an auth provider for this account if needed
    auth_provider = Portal.AuthProviderFixtures.email_otp_provider_fixture(account: account)

    authorize_conn_with_provider(conn, actor, auth_provider)
  end

  def authorize_conn_with_provider(conn, %Portal.Actor{} = actor, provider) do
    {"user-agent", user_agent} = List.keyfind(conn.req_headers, "user-agent", 0, "FooBar 1.1")

    context = %Portal.Authentication.Context{
      type: :portal,
      user_agent: user_agent,
      remote_ip_location_region: "UA",
      remote_ip_location_city: "Kyiv",
      remote_ip_location_lat: 50.4501,
      remote_ip_location_lon: 30.5234,
      remote_ip: conn.remote_ip
    }

    expires_at = DateTime.add(DateTime.utc_now(), 300, :second)

    {:ok, session} =
      Portal.Authentication.create_portal_session(
        actor,
        provider.id,
        context,
        expires_at
      )

    {:ok, subject} = Portal.Authentication.build_subject(session, context)

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

  @doc """
  Signs in for the app-approval flow only.

  Sets just the short lived `oauth_sess_<account_id>` cookie and no assigns, so
  the request goes through the real plugs. A portal session will not do here,
  and this one will not do for the portal.
  """
  def authorize_oauth_conn(conn, %Portal.Actor{} = actor) do
    account = Portal.Repo.get!(Portal.Account, actor.account_id)
    provider = Portal.AuthProviderFixtures.email_otp_provider_fixture(account: account)

    context = %Portal.Authentication.Context{
      type: :portal,
      user_agent: "FooBar 1.1",
      remote_ip_location_region: "UA",
      remote_ip_location_city: "Kyiv",
      remote_ip_location_lat: 50.4501,
      remote_ip_location_lon: 30.5234,
      remote_ip: conn.remote_ip
    }

    expires_at =
      DateTime.add(DateTime.utc_now(), PortalWeb.Cookie.OAuthSession.lifetime_secs(), :second)

    {:ok, session} =
      Portal.Authentication.create_portal_session(actor, provider.id, context, expires_at)

    cookie = %PortalWeb.Cookie.OAuthSession{session_id: session.id}
    conn = PortalWeb.Cookie.OAuthSession.put(conn, account.id, cookie)
    cookie_name = "oauth_sess_#{account.id}"

    put_req_cookie(conn, cookie_name, conn.resp_cookies[cookie_name].value)
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

  def element_to_text(element) do
    element
    |> Floki.text()
    |> String.replace(~r|[\n\s ]+|, " ")
    |> String.trim()
  end

end
