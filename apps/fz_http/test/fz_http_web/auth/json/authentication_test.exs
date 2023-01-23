defmodule FzHttpWeb.Auth.JSON.AuthenticationTest do
  use FzHttpWeb.ApiCase, async: true
  alias FzHttp.UsersFixtures
  import FzHttpWeb.ApiCase

  test "renders error when api token is invalid" do
    conn =
      api_conn()
      |> Plug.Conn.put_req_header("authorization", "bearer invalid")
      |> FzHttpWeb.Auth.JSON.Pipeline.call([])

    assert json_response(conn, 401) == %{"errors" => %{"auth" => "invalid_token"}}
  end

  test "renders error when api token resource is invalid" do
    user = UsersFixtures.user(%{role: :admin})

    claims = %{
      "api" => Ecto.UUID.generate(),
      "exp" => DateTime.to_unix(DateTime.utc_now() |> DateTime.add(1, :hour))
    }

    {:ok, token, _claims} =
      Guardian.encode_and_sign(FzHttpWeb.Auth.JSON.Authentication, user, claims)

    conn =
      api_conn()
      |> Plug.Conn.put_req_header("authorization", "bearer #{token}")
      |> FzHttpWeb.Auth.JSON.Pipeline.call([])

    assert json_response(conn, 401) == %{"errors" => %{"auth" => "no_resource_found"}}
  end
end
