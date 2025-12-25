defmodule PortalAPI.ConnCase do
  use ExUnit.CaseTemplate
  use Portal.CaseTemplate
  import Portal.TokenFixtures

  using do
    quote do
      # The default endpoint for testing
      @endpoint PortalAPI.Endpoint

      use PortalAPI, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import PortalAPI.ConnCase

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

    conn = %{conn | secret_key_base: PortalAPI.Endpoint.config(:secret_key_base)}

    {:ok, conn: conn, user_agent: user_agent}
  end

  def authorize_conn(conn, %Portal.Actor{account: account} = actor) do
    expires_at = DateTime.utc_now() |> DateTime.add(300, :second)
    api_token = api_token_fixture(actor: actor, account: account, expires_at: expires_at)
    encoded_fragment = encode_api_token(api_token)

    Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> encoded_fragment)
  end

  def equal_ids?(list1, list2) do
    MapSet.equal?(MapSet.new(list1), MapSet.new(list2))
  end
end
