defmodule FzHttpWeb.ApiCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.

  Such tests rely on `Phoenix.ConnTest` and also
  import other functionality to make it easier
  to build common data structures and query the data layer.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use FzHttpWeb.ConnCase, async: true`, although
  this option is not recommended for other databases.
  """
  use ExUnit.CaseTemplate
  use FzHttp.CaseTemplate

  alias FzHttp.{
    ApiTokensFixtures,
    UsersFixtures
  }

  using do
    quote do
      use FzHttpWeb, :verified_routes
      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import FzHttpWeb.ApiCase
      import FzHttp.TestHelpers
      import Bureaucrat.Helpers
      import FzHttpWeb.ApiCase
      alias FzHttp.Repo

      # The default endpoint for testing
      @endpoint FzHttpWeb.Endpoint
    end
  end

  def new_conn do
    Phoenix.ConnTest.build_conn()
  end

  def api_conn do
    new_conn()
    |> Plug.Conn.put_req_header("accept", "application/json")
  end

  def unauthed_conn, do: api_conn()

  def authed_conn do
    user = UsersFixtures.create_user_with_role(:admin)
    api_token = ApiTokensFixtures.create_api_token(user: user)

    {:ok, token, _claims} = FzHttpWeb.Auth.JSON.Authentication.fz_encode_and_sign(api_token)

    api_conn()
    |> Plug.Conn.put_req_header("authorization", "bearer #{token}")
    |> FzHttpWeb.Auth.JSON.Pipeline.call([])
  end
end
