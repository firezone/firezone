defmodule FzHttpWeb.HeaderHelpersTest do
  use ExUnit.Case, async: true
  import FzHttpWeb.HeaderHelpers

  describe "remote_ip_opts/0" do
    test "returns a list of options for remote_ip/2" do
      FzHttp.Config.put_env_override(:fz_http, :external_trusted_proxies, [
        "127.0.0.1",
        "10.10.10.0/16"
      ])

      assert remote_ip_opts() == [
               headers: ["x-forwarded-for"],
               proxies: "127.0.0.1, 10.10.10.0/16",
               clients: ["172.28.0.0/16"]
             ]
    end
  end
end
