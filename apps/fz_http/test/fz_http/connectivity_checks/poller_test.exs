defmodule FzHttp.ConnectivityChecks.PollerTest do
  @moduledoc """
  Tests the ConnectivityCheckService module.
  """
  use FzHttp.DataCase, async: true
  alias FzHttp.ConnectivityChecks
  import FzHttp.ConnectivityChecks.Poller

  describe "every tick" do
    test "checks connectivity of a given url" do
      bypass = Bypass.open()

      Bypass.expect(bypass, fn conn ->
        Plug.Conn.resp(conn, 200, "OK")
      end)

      request = Finch.build(:post, "http://localhost:#{bypass.port}/")

      assert handle_info(:tick, %{request: request}) == {:noreply, %{request: request}}

      assert Repo.one(ConnectivityChecks.ConnectivityCheck)
    end

    test "does not crash when connectivity check failed" do
      bypass = Bypass.open()
      request = Finch.build(:post, "http://localhost:#{bypass.port}/")

      Bypass.down(bypass)

      assert handle_info(:tick, %{request: request}) == {:noreply, %{request: request}}

      refute Repo.one(ConnectivityChecks.ConnectivityCheck)
    end
  end
end
