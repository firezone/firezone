defmodule API.ConnCase do
  use ExUnit.CaseTemplate
  use Domain.CaseTemplate
  import Domain.TokenFixtures

  using do
    quote do
      # The default endpoint for testing
      @endpoint API.Endpoint

      use API, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import API.ConnCase

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

    conn = %{conn | secret_key_base: API.Endpoint.config(:secret_key_base)}

    {:ok, conn: conn, user_agent: user_agent}
  end

  def authorize_conn(conn, %Domain.Actor{account: account} = actor) do
    expires_at = DateTime.utc_now() |> DateTime.add(300, :second)
    api_token = api_token_fixture(actor: actor, account: account, expires_at: expires_at)
    encoded_fragment = encode_api_token(api_token)

    Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> encoded_fragment)
  end

  def equal_ids?(list1, list2) do
    MapSet.equal?(MapSet.new(list1), MapSet.new(list2))
  end
end
