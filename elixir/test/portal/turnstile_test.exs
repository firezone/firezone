defmodule Portal.TurnstileTest do
  use ExUnit.Case, async: true

  alias Portal.Turnstile

  describe "without keys" do
    test "is disabled and accepts any token without calling Cloudflare" do
      refute Turnstile.enabled?()
      assert :ok = Turnstile.verify(nil, {203, 0, 113, 7})
      assert :ok = Turnstile.verify("anything", nil)
    end
  end

  describe "with keys" do
    setup do
      Portal.Config.put_env_override(:portal, Turnstile,
        site_key: "site-key",
        secret_key: "secret-key",
        req_opts: [retry: false, plug: {Req.Test, __MODULE__}]
      )

      :ok
    end

    test "is enabled and exposes the site key" do
      assert Turnstile.enabled?()
      assert Turnstile.site_key() == "site-key"
    end

    test "trims whitespace around both keys" do
      Portal.Config.merge_env_override(:portal, Turnstile, site_key: " site-key\n", secret_key: "\tsecret-key ")
      test_pid = self()

      Req.Test.expect(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:form, URI.decode_query(body)})
        Req.Test.json(conn, %{"success" => true})
      end)

      assert Turnstile.enabled?()
      assert Turnstile.site_key() == "site-key"
      assert :ok = Turnstile.verify("token-1", nil)
      assert_receive {:form, %{"secret" => "secret-key"}}
    end

    test "is disabled when only one key is set" do
      Portal.Config.put_env_override(:portal, Turnstile, secret_key: " ")
      refute Turnstile.enabled?()
    end

    test "rejects a missing or empty token without calling Cloudflare" do
      assert {:error, :missing_token} = Turnstile.verify(nil, nil)
      assert {:error, :missing_token} = Turnstile.verify("", nil)
      assert {:error, :invalid_token} = Turnstile.verify(String.duplicate("a", 2049), nil)
    end

    test "accepts a token Cloudflare approves and sends the secret, token and client IP" do
      test_pid = self()

      Req.Test.expect(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:form, URI.decode_query(body)})
        Req.Test.json(conn, %{"success" => true})
      end)

      assert :ok = Turnstile.verify("token-1", {203, 0, 113, 7})

      assert_receive {:form, form}
      assert form == %{"secret" => "secret-key", "response" => "token-1", "remoteip" => "203.0.113.7"}
    end

    test "omits the client IP when it is unknown" do
      test_pid = self()

      Req.Test.expect(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:form, URI.decode_query(body)})
        Req.Test.json(conn, %{"success" => true})
      end)

      assert :ok = Turnstile.verify("token-1", nil)
      assert_receive {:form, form}
      refute Map.has_key?(form, "remoteip")
    end

    test "rejects a token Cloudflare refuses" do
      Req.Test.expect(__MODULE__, fn conn ->
        Req.Test.json(conn, %{"success" => false, "error-codes" => ["timeout-or-duplicate"]})
      end)

      assert {:error, :invalid_token} = Turnstile.verify("token-1", nil)
    end

    test "fails closed when Cloudflare errors" do
      Req.Test.expect(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "unavailable") end)
      assert {:error, :unavailable} = Turnstile.verify("token-1", nil)
    end

    test "formats an IPv6 client address for Cloudflare" do
      test_pid = self()

      Req.Test.expect(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:form, URI.decode_query(body)})
        Req.Test.json(conn, %{"success" => true})
      end)

      assert :ok = Turnstile.verify("token-1", {0x2001, 0xDB8, 0, 0, 0, 0, 0, 1})
      assert_receive {:form, %{"remoteip" => "2001:db8::1"}}
    end

    test "fails closed on a client error from Cloudflare" do
      Req.Test.expect(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 400, "bad request") end)
      assert {:error, :unavailable} = Turnstile.verify("token-1", nil)
    end

    test "fails closed on a 200 response without a verdict" do
      Req.Test.expect(__MODULE__, fn conn -> Req.Test.json(conn, %{"unexpected" => true}) end)
      assert {:error, :unavailable} = Turnstile.verify("token-1", nil)
    end

    test "is disabled when only the secret key is set" do
      Portal.Config.put_env_override(:portal, Turnstile, site_key: nil)
      refute Turnstile.enabled?()
    end

    test "fails closed when Cloudflare is unreachable" do
      Req.Test.expect(__MODULE__, &Req.Test.transport_error(&1, :econnrefused))
      assert {:error, :unavailable} = Turnstile.verify("token-1", nil)
    end
  end
end
