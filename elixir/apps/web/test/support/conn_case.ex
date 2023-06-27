defmodule Web.ConnCase do
  use ExUnit.CaseTemplate
  use Domain.CaseTemplate

  using do
    quote do
      # The default endpoint for testing
      @endpoint Web.Endpoint

      use Web, :verified_routes

      # Import conveniences for testing with connections
      import Plug.Conn
      import Phoenix.ConnTest
      import Phoenix.LiveViewTest
      import Web.ConnCase

      import Swoosh.TestAssertions

      alias Domain.Repo
    end
  end

  setup _tags do
    user_agent = "testing"

    conn =
      Phoenix.ConnTest.build_conn()
      |> Plug.Conn.put_req_header("user-agent", user_agent)
      |> Plug.Test.init_test_session(%{})

    {:ok, conn: conn, user_agent: user_agent}
  end

  def flash(conn, key) do
    Phoenix.Flash.get(conn.assigns.flash, key)
  end

  def authorize_conn(conn, identity) do
    expires_in = DateTime.utc_now() |> DateTime.add(300, :second)
    {"user-agent", user_agent} = List.keyfind(conn.req_headers, "user-agent", 0, "FooBar 1.1")
    subject = Domain.Auth.build_subject(identity, expires_in, user_agent, conn.remote_ip)

    conn
    |> Web.Auth.renew_session()
    |> Web.Auth.put_subject_in_session(subject)
  end

  # @doc """
  # Logs the given `user` into the `conn`.

  # It returns an updated `conn`.
  # """
  # def log_in_user(conn, user) do
  #   token = Domain.Accounts.generate_user_session_token(user)

  #   conn
  #   |> Phoenix.ConnTest.init_test_session(%{})
  #   |> Plug.Conn.put_session(:user_token, token)
  # end
end
