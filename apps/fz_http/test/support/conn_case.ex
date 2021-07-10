defmodule FzHttpWeb.ConnCase do
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

  alias Ecto.Adapters.SQL.Sandbox

  alias FzHttp.Fixtures

  using do
    quote do
      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import FzHttp.TestHelpers
      alias FzHttpWeb.Router.Helpers, as: Routes

      # The default endpoint for testing
      @endpoint FzHttpWeb.Endpoint
    end
  end

  def new_conn do
    Phoenix.ConnTest.build_conn()
  end

  def authed_conn do
    session = Fixtures.session()

    {session.id,
     new_conn()
     |> Plug.Test.init_test_session(%{user_id: session.id})}
  end

  setup tags do
    :ok = Sandbox.checkout(FzHttp.Repo)

    unless tags[:async] do
      Sandbox.mode(FzHttp.Repo, {:shared, self()})
    end

    {user_id, authed_conn} = authed_conn()
    {:ok, user_id: user_id, unauthed_conn: new_conn(), authed_conn: authed_conn}
  end
end
