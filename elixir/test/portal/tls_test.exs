defmodule Portal.TLSTest do
  use ExUnit.Case, async: true

  import Portal.DeviceTrustFixtures

  alias Portal.TLS

  defmodule PeerCertificatePlug do
    import Plug.Conn

    def init(opts), do: opts

    def call(conn, _opts) do
      peer_data = get_peer_data(conn)
      send_resp(conn, :ok, if(peer_data.ssl_cert, do: "present", else: "absent"))
    end
  end

  test "selects certificates by SNI hostname" do
    sni_fun =
      TLS.sni_fun(
        %{
          "api.firezone.test" => %{
            "certfile" => "/certs/api.crt",
            "keyfile" => "/certs/api.key"
          }
        },
        nil
      )

    assert sni_fun.(~c"API.FIREZONE.TEST") == [
             certfile: ~c"/certs/api.crt",
             keyfile: ~c"/certs/api.key"
           ]

    assert sni_fun.(~c"unknown.firezone.test") == :unrecognized
  end

  test "requires but defers validation of the mutual-TLS client certificate" do
    sni_fun =
      TLS.sni_fun(
        %{
          "mtls.firezone.test" => %{
            "certfile" => "/certs/mtls.crt",
            "keyfile" => "/certs/mtls.key"
          }
        },
        "https://mtls.firezone.test/"
      )

    options = sni_fun.(~c"mtls.firezone.test")

    assert options[:verify] == :verify_peer
    assert options[:fail_if_no_peer_cert]
    assert options[:certificate_authorities] == false
    assert options[:cacerts] == []

    {verify_fun, state} = options[:verify_fun]
    assert verify_fun.(:certificate, {:bad_cert, :unknown_ca}, state) == {:valid, state}
  end

  test "rejects malformed host configurations" do
    assert_raise ArgumentError, fn ->
      TLS.sni_fun(%{"api.firezone.test" => %{"certfile" => "/certs/api.crt"}}, nil)
    end
  end

  test "Bandit exposes the certificate required by the mutual-TLS SNI host" do
    {certfile, keyfile} = write_certificate_files()

    sni_fun =
      TLS.sni_fun(
        %{
          "api.firezone.test" => %{"certfile" => certfile, "keyfile" => keyfile},
          "mtls.firezone.test" => %{"certfile" => certfile, "keyfile" => keyfile}
        },
        "https://mtls.firezone.test/"
      )

    server =
      start_supervised!({Bandit,
       plug: PeerCertificatePlug,
       scheme: :https,
       port: 0,
       startup_log: false,
       thousand_island_options: [transport_options: [sni_fun: sni_fun]]})

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)

    assert {:ok, socket} = connect(port, "api.firezone.test", [])
    assert request(socket, "api.firezone.test") =~ "absent"

    assert_client_certificate_required(connect(port, "mtls.firezone.test", []))

    assert {:ok, socket} =
             connect(port, "mtls.firezone.test", certfile: certfile, keyfile: keyfile)

    assert request(socket, "mtls.firezone.test") =~ "present"
  end

  defp connect(port, host, options) do
    options =
      [
        active: false,
        mode: :binary,
        verify: :verify_none,
        server_name_indication: String.to_charlist(host)
      ] ++ options

    :ssl.connect(~c"127.0.0.1", port, options, 5_000)
  end

  defp request(socket, host) do
    :ok = :ssl.send(socket, ["GET / HTTP/1.1\r\nHost: ", host, "\r\nConnection: close\r\n\r\n"])
    {:ok, response} = :ssl.recv(socket, 0, 5_000)
    response
  end

  defp assert_client_certificate_required({:error, _reason}), do: :ok

  defp assert_client_certificate_required({:ok, socket}) do
    _result = :ssl.send(socket, "GET / HTTP/1.1\r\nHost: mtls.firezone.test\r\n\r\n")
    assert {:error, _reason} = :ssl.recv(socket, 0, 5_000)
  end

  defp write_certificate_files do
    pki = pki()
    directory = Path.join(System.tmp_dir!(), "portal-tls-#{System.unique_integer([:positive])}")
    certfile = Path.join(directory, "cert.pem")
    keyfile = Path.join(directory, "key.pem")

    File.mkdir_p!(directory)
    File.write!(certfile, Portal.Crypto.X509.pem_encode(pki.ca_der))

    File.write!(
      keyfile,
      :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, pki.ca.key)])
    )

    on_exit(fn -> File.rm_rf!(directory) end)

    {certfile, keyfile}
  end
end
