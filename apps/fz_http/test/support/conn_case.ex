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
  use FzHttp.CaseTemplate

  alias FzHttp.UsersFixtures
  alias FzHttpWeb.Auth.HTML.Authentication

  using do
    quote do
      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import FzHttp.TestHelpers

      # The default endpoint for testing
      @endpoint FzHttpWeb.Endpoint

      use FzHttpWeb, :verified_routes

      def current_user(test_conn) do
        get_session(test_conn)
        |> Authentication.get_current_user()
      end
    end
  end

  # def assert_element(html, selector) do
  #   elements = Floki.find(html, selector)

  # end

  def new_conn do
    Phoenix.ConnTest.build_conn()
  end

  def admin_conn(tags) do
    authed_conn(:admin, tags)
  end

  def unprivileged_conn(tags) do
    authed_conn(:unprivileged, tags)
  end

  defp authed_conn(role, tags) do
    user = UsersFixtures.user(%{role: role})

    conn =
      new_conn()
      |> Plug.Test.init_test_session(%{})
      |> Authentication.sign_in(user, %{provider: :identity})
      |> maybe_put_session(tags)

    {user,
     conn
     |> Plug.Conn.put_session("guardian_default_token", conn.private.guardian_default_token)}
  end

  defp maybe_put_session(conn, %{session: session}) do
    conn
    |> Plug.Test.init_test_session(session)
  end

  defp maybe_put_session(conn, _tags) do
    conn
  end

  setup tags do
    {unprivileged_user, unprivileged_conn} = unprivileged_conn(tags)
    {admin_user, admin_conn} = admin_conn(tags)

    conns = [
      unauthed_conn: new_conn(),
      admin_user: admin_user,
      unprivileged_user: unprivileged_user,
      admin_conn: admin_conn,
      unprivileged_conn: unprivileged_conn
    ]

    {:ok, conns}
  end
end
