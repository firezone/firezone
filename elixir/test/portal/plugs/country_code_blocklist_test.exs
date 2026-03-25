defmodule Portal.Plugs.CountryCodeBlocklistTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias Portal.Plugs.CountryCodeBlocklist

  describe "call/2" do
    test "passes through when blocklist is empty" do
      Portal.Config.put_env_override(:country_code_blocklist, [])

      conn =
        conn(:get, "/")
        |> put_req_header("x-azure-geo-country", "UA")
        |> put_remote_ip({100, 64, 0, 1})
        |> CountryCodeBlocklist.call(CountryCodeBlocklist.init([]))

      refute conn.halted
      assert conn.status == nil
    end

    test "halts with 403 when country is blocked" do
      Portal.Config.put_env_override(:country_code_blocklist, ["UA", "RU"])

      conn =
        conn(:get, "/")
        |> put_req_header("x-azure-geo-country", "UA")
        |> put_remote_ip({100, 64, 0, 2})
        |> CountryCodeBlocklist.call(CountryCodeBlocklist.init([]))

      assert conn.halted
      assert conn.status == 403
      assert conn.resp_body == "Forbidden"
    end

    test "allows request when country is not blocked" do
      Portal.Config.put_env_override(:country_code_blocklist, ["UA", "RU"])

      conn =
        conn(:get, "/")
        |> put_req_header("x-azure-geo-country", "US")
        |> put_remote_ip({100, 64, 0, 3})
        |> CountryCodeBlocklist.call(CountryCodeBlocklist.init([]))

      refute conn.halted
      assert conn.status == nil
    end

    test "passes through when country cannot be resolved" do
      Portal.Config.put_env_override(:country_code_blocklist, ["UA"])

      conn =
        conn(:get, "/")
        |> put_remote_ip({100, 64, 0, 4})
        |> CountryCodeBlocklist.call(CountryCodeBlocklist.init([]))

      refute conn.halted
      assert conn.status == nil
    end
  end

  defp put_remote_ip(conn, ip) do
    %{conn | remote_ip: ip}
  end
end
