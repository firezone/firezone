defmodule Portal.Req.SSRFProtectionTest do
  use ExUnit.Case, async: true

  alias Portal.Req.SSRFProtection
  alias Portal.Req.SSRFProtection.UnsafeURLError

  test "is configured as a global Req plugin" do
    assert SSRFProtection in Keyword.fetch!(Req.default_options(), :plugins)

    assert {:error, %UnsafeURLError{reason: :non_public_address}} =
             Req.get("http://127.0.0.1", retry: false)
  end

  test "the global allow_private_ips escape hatch reaches an explicit loopback address" do
    {:ok, listen_socket} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :raw, reuseaddr: true])

    {:ok, {_address, port}} = :inet.sockname(listen_socket)

    server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listen_socket)
        {:ok, _request} = :gen_tcp.recv(socket, 0, 1_000)

        :ok =
          :gen_tcp.send(
            socket,
            "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
          )

        :gen_tcp.close(socket)
      end)

    assert {:ok, %Req.Response{status: 204}} =
             Req.get("http://127.0.0.1:#{port}", allow_private_ips: true, retry: false)

    Task.await(server)
    :gen_tcp.close(listen_socket)
  end

  test "blocks literal private and reserved IPv4 and IPv6 addresses before the adapter runs" do
    urls = [
      "https://169.254.169.254/latest/meta-data",
      "http://[::1]/metadata",
      "http://[::ffff:127.0.0.1]/metadata"
    ]

    for url <- urls do
      request = protected_request(url, unreachable_adapter())

      assert {:error, %UnsafeURLError{reason: :non_public_address}} = Req.get(request)
    end
  end

  test "allows and pins literal public IPv4 addresses without a DNS lookup" do
    test_pid = self()
    resolver = fn _host, _family -> flunk("literal IP addresses must not use DNS") end

    adapter = fn request ->
      send(test_pid, {:request, request})
      {request, Req.Response.new(status: 204)}
    end

    request =
      protected_request("https://8.8.8.8:8443/events", adapter, resolver: resolver)

    assert {:ok, %Req.Response{status: 204}} = Req.get(request)
    assert_receive {:request, pinned_request}
    assert pinned_request.url.host == "8.8.8.8"
    assert Req.Request.get_header(pinned_request, "host") == ["8.8.8.8:8443"]
    assert pinned_request.options[:connect_options][:hostname] == "8.8.8.8"
    refute pinned_request.options[:inet6]
  end

  test "allows and pins literal public IPv6 addresses with a bracketed Host header" do
    test_pid = self()
    resolver = fn _host, _family -> flunk("literal IP addresses must not use DNS") end

    adapter = fn request ->
      send(test_pid, {:request, request})
      {request, Req.Response.new(status: 204)}
    end

    request =
      protected_request("https://[2606:4700:4700::1111]:8443/events", adapter,
        resolver: resolver
      )

    assert {:ok, %Req.Response{status: 204}} = Req.get(request)
    assert_receive {:request, pinned_request}
    assert pinned_request.url.host == "2606:4700:4700::1111"
    assert Req.Request.get_header(pinned_request, "host") == ["[2606:4700:4700::1111]:8443"]
    assert pinned_request.options[:connect_options][:hostname] == "2606:4700:4700::1111"
    assert pinned_request.options[:inet6]
  end

  test "blocks a hostname when any DNS answer is non-public" do
    resolver = fn
      ~c"logs.example.com", :inet -> {:ok, [{8, 8, 8, 8}, {10, 0, 0, 1}]}
      ~c"logs.example.com", :inet6 -> {:error, :nxdomain}
    end

    request =
      protected_request("https://logs.example.com", unreachable_adapter(), resolver: resolver)

    assert {:error, %UnsafeURLError{reason: :non_public_address}} = Req.get(request)
  end

  test "fails closed when a hostname has no DNS answers" do
    resolver = fn _host, _family -> {:error, :nxdomain} end
    request = protected_request("https://missing.example.com", unreachable_adapter(), resolver: resolver)

    assert {:error, %UnsafeURLError{reason: :nxdomain}} = Req.get(request)
  end

  test "pins the connection to a checked address and preserves the HTTP and TLS hostname" do
    test_pid = self()

    resolver = fn
      ~c"logs.example.com", :inet -> {:ok, [{8, 8, 8, 8}]}
      ~c"logs.example.com", :inet6 -> {:error, :nxdomain}
    end

    adapter = fn request ->
      send(test_pid, {:request, request})
      {request, Req.Response.new(status: 204)}
    end

    request =
      protected_request("https://logs.example.com:8443/events", adapter, resolver: resolver)

    assert {:ok, %Req.Response{status: 204}} = Req.get(request)
    assert_receive {:request, pinned_request}
    assert pinned_request.url.host == "8.8.8.8"
    assert Req.Request.get_header(pinned_request, "host") == ["logs.example.com:8443"]
    assert pinned_request.options[:connect_options][:hostname] == "logs.example.com"
  end

  test "checks the destination of every redirect" do
    test_pid = self()

    resolver = fn
      ~c"public.example.com", :inet -> {:ok, [{8, 8, 8, 8}]}
      ~c"public.example.com", :inet6 -> {:error, :nxdomain}
      ~c"private.example.com", :inet -> {:ok, [{10, 0, 0, 1}]}
      ~c"private.example.com", :inet6 -> {:error, :nxdomain}
    end

    adapter = fn request ->
      send(test_pid, :adapter_called)

      response =
        Req.Response.new(
          status: 302,
          headers: [{"location", "https://private.example.com/metadata"}]
        )

      {request, response}
    end

    request = protected_request("https://public.example.com", adapter, resolver: resolver)

    assert {:error, %UnsafeURLError{reason: :non_public_address}} = Req.get(request)
    assert_receive :adapter_called
    refute_receive :adapter_called
  end

  test "allow_private_ips bypasses protection for literal private IPv4 and IPv6 hosts" do
    test_pid = self()

    adapter = fn request ->
      send(test_pid, {:request, request})
      {request, Req.Response.new(status: 200)}
    end

    urls = [
      "http://169.254.169.254/metadata/identity/oauth2/token",
      "http://[::1]/metadata/identity/oauth2/token"
    ]

    for url <- urls do
      request = protected_request(url, adapter, allow_private_ips: true)

      assert {:ok, %Req.Response{status: 200}} = Req.get(request)
      assert_receive {:request, request}
      assert request.url.host == URI.parse(url).host
      assert Req.Request.get_header(request, "host") == []
      refute request.options[:connect_options][:hostname]
    end
  end

  defp protected_request(url, adapter, options \\ []) do
    {resolver, options} = Keyword.pop(options, :resolver)

    Req.new(url: url, adapter: adapter, retry: false)
    |> SSRFProtection.attach(resolver: resolver || (&:inet.getaddrs/2))
    |> Req.merge(options)
  end

  defp unreachable_adapter do
    fn _request -> flunk("adapter must not run for an unsafe URL") end
  end
end
