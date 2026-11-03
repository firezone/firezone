defmodule PortalWeb.Plugs.PutSecurityHeadersTest do
  use ExUnit.Case, async: true

  import Plug.Conn
  import Plug.Test

  alias PortalWeb.Plugs.PutSecurityHeaders

  @cloudflare "https://challenges.cloudflare.com"

  defp csp(path) do
    :get
    |> conn(path)
    |> PutSecurityHeaders.call([])
    |> get_resp_header("content-security-policy")
    |> List.first()
    |> String.split("; ")
    |> Map.new(fn directive ->
      [name | sources] = String.split(directive, " ")
      {name, sources}
    end)
  end

  describe "Turnstile on the sign-up pages" do
    for path <- ["/sign_up", "/sign_up/email", "/sign_up/google", "/sign_up/github"] do
      @path path

      test "#{path} may load, connect to and frame Cloudflare" do
        csp = csp(@path)

        for directive <- ["script-src", "connect-src", "frame-src"] do
          assert @cloudflare in csp[directive], "#{directive} is missing Cloudflare"
        end
      end
    end

    test "connect-src and frame-src keep the sources they fell back to from default-src" do
      csp = csp("/sign_up/email")

      for directive <- ["connect-src", "frame-src"] do
        assert Enum.all?(csp["default-src"], &(&1 in csp[directive]))
      end
    end

    test "script-src keeps the nonce and its own sources" do
      script_src = csp("/sign_up")["script-src"]

      assert "'self'" in script_src
      assert Enum.any?(script_src, &String.starts_with?(&1, "'nonce-"))
    end
  end

  describe "every other page" do
    for path <- ["/", "/sign_in", "/verify_sign_up", "/sign_upfoo", "/acme/sites", "/acme/settings/account"] do
      @path path

      test "#{path} does not allow Cloudflare" do
        csp = csp(@path)

        for directive <- ["script-src", "connect-src", "frame-src"] do
          refute @cloudflare in Map.get(csp, directive, [])
        end
      end
    end

    test "the default policy has no connect-src or frame-src of its own" do
      csp = csp("/sign_in")

      refute Map.has_key?(csp, "connect-src")
      refute Map.has_key?(csp, "frame-src")
    end
  end
end
