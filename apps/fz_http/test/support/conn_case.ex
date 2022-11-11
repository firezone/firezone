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

  alias FzHttp.UsersFixtures

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

      def current_user(test_conn) do
        get_session(test_conn)
        |> FzHttpWeb.Authentication.get_current_user()
      end
    end
  end

  def new_conn do
    Phoenix.ConnTest.build_conn()
  end

  def admin_conn do
    authed_conn(:admin)
  end

  def unprivileged_conn do
    authed_conn(:unprivileged)
  end

  defp put_token(conn) do
    conn
    |> Plug.Conn.put_session(
      "guardian_default_token",
      conn.private.guardian_default_token
    )
  end

  defp authed_conn(role) do
    user = UsersFixtures.user(%{role: role})

    {
      user,
      new_conn()
      |> Plug.Test.init_test_session(%{})
      |> FzHttpWeb.Authentication.sign_in(user, %{provider: :identity})
      |> put_token()
    }
  end

  setup tags do
    :ok = Sandbox.checkout(FzHttp.Repo)

    unless tags[:async] do
      Sandbox.mode(FzHttp.Repo, {:shared, self()})
    end

    {unprivileged_user, unprivileged_conn} = unprivileged_conn()
    {admin_user, admin_conn} = admin_conn()

    {:ok,
     unauthed_conn: new_conn(),
     admin_user: admin_user,
     unprivileged_user: unprivileged_user,
     admin_conn: admin_conn,
     unprivileged_conn: unprivileged_conn}
  end
end
