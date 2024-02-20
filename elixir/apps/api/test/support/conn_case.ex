defmodule API.ConnCase do
  use ExUnit.CaseTemplate
  use Domain.CaseTemplate

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

  def authorize_conn(conn, %Domain.Actors.Actor{} = actor) do
    expires_in = DateTime.utc_now() |> DateTime.add(300, :second)
    {"user-agent", user_agent} = List.keyfind(conn.req_headers, "user-agent", 0)

    attrs = %{
      "name" => "conn_case_token",
      "expires_at" => expires_in,
      "type" => :api_client,
      "secret_fragment" => Domain.Crypto.random_token(32, encoder: :hex32),
      "account_id" => actor.account_id,
      "actor_id" => actor.id,
      "created_by_user_agent" => user_agent,
      "created_by_remote_ip" => conn.remote_ip
    }

    {:ok, token} = Domain.Tokens.create_token(attrs)
    encoded_fragment = Domain.Tokens.encode_fragment!(token)

    Plug.Conn.put_req_header(conn, "authorization", "Bearer " <> encoded_fragment)
  end
end
