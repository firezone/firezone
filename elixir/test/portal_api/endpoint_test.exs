defmodule PortalAPI.EndpointTest do
  use ExUnit.Case, async: true

  alias Portal.CertCache

  @cert_pem """
  -----BEGIN CERTIFICATE-----
  MIIBfDCCASGgAwIBAgIUNA/rm6OyDI04QMiSBAKOr4NncrIwCgYIKoZIzj0EAwIw
  EzERMA8GA1UEAwwIYXBpLXRlc3QwHhcNMjYwMzI4MjEzMTE4WhcNMzYwMzI1MjEz
  MTE4WjATMREwDwYDVQQDDAhhcGktdGVzdDBZMBMGByqGSM49AgEGCCqGSM49AwEH
  A0IABPAWDZKGQC6WAGUnO13NPnn7xV8CMgI2cpsHYShBvypO//6ytmsPQIv6WVAH
  uL1zJYRTpZPwi71lbgr0d5rYAumjUzBRMB0GA1UdDgQWBBTUvDn6QPxmVyw1IBQl
  jjV7IBVX2zAfBgNVHSMEGDAWgBTUvDn6QPxmVyw1IBQljjV7IBVX2zAPBgNVHRMB
  Af8EBTADAQH/MAoGCCqGSM49BAMCA0kAMEYCIQDs7QNYIp6HQ/nQGEwHtZP2GztS
  wUUHBEzN8LQKER/++AIhAKQCEUQ6464RxvEUnkclHMVBShUrvuY4SiTGEeb/DRuA
  -----END CERTIFICATE-----
  """

  @key_pem """
  -----BEGIN PRIVATE KEY-----
  MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQginP8UwWhtNoCGv+k
  E4xnfS04OqzcJA6jjhedpi8HeomhRANCAATwFg2ShkAulgBlJztdzT55+8VfAjIC
  NnKbB2EoQb8qTv/+srZrD0CL+llQB7i9cyWEU6WT8Iu9ZW4K9Hea2ALp
  -----END PRIVATE KEY-----
  """

  describe "TLS termination" do
    test "Bandit serves the CertCache certificate via sni_fun" do
      cache_name = :"api_cert_cache_#{System.unique_integer([:positive])}"
      bandit_name = :"bandit_api_#{System.unique_integer([:positive])}"

      start_supervised!(
        {CertCache, name: cache_name, fetch_fn: fn -> {:ok, @cert_pem, @key_pem} end}
      )

      [cert: [expected_cert_der], key: _] = CertCache.get_opts(cache_name)

      start_supervised!(
        {Bandit,
         plug: PortalAPI.Endpoint,
         scheme: :https,
         port: 0,
         ip: {127, 0, 0, 1},
         thousand_island_options: [
           transport_options: [
             sni_fun: fn _hostname -> CertCache.get_opts(cache_name) end
           ],
           supervisor_options: [name: bandit_name]
         ],
         startup_log: false}
      )

      {:ok, {_ip, port}} = ThousandIsland.listener_info(bandit_name)

      {:ok, ssl_socket} =
        :ssl.connect(~c"127.0.0.1", port,
          verify: :verify_none,
          versions: [:"tlsv1.3", :"tlsv1.2"]
        )

      {:ok, peer_cert_der} = :ssl.peercert(ssl_socket)
      :ssl.close(ssl_socket)

      assert peer_cert_der == expected_cert_der
    end
  end
end
