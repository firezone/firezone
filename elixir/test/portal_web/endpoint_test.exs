defmodule PortalWeb.EndpointTest do
  use ExUnit.Case, async: true

  alias Portal.CertCache

  @cert_pem """
  -----BEGIN CERTIFICATE-----
  MIIBdDCCARmgAwIBAgIUd14Z3M5mEy8oeLCWeWVyqZ7F+wowCgYIKoZIzj0EAwIw
  DzENMAsGA1UEAwwEdGVzdDAeFw0yNjAzMjgxMzIzMzhaFw0zNjAzMjUxMzIzMzha
  MA8xDTALBgNVBAMMBHRlc3QwWTATBgcqhkjOPQIBBggqhkjOPQMBBwNCAASQbwr1
  68E5NN7/m+yFh9pIse10XfPvbn9Vw0EU8xRfhLcW20dxFoBC7xF4GbcxtrBKAr23
  FbDMjikhZTmO6utwo1MwUTAdBgNVHQ4EFgQUGTMLuMNOhp8P6Ih5LO1BK4x/po0w
  HwYDVR0jBBgwFoAUGTMLuMNOhp8P6Ih5LO1BK4x/po0wDwYDVR0TAQH/BAUwAwEB
  /zAKBggqhkjOPQQDAgNJADBGAiEAutiiDVMimmAylG9iuGzEE0yFKQjZ2v0EQDYQ
  jUk9UjECIQDJK9fv/PIha8SVplYOUw3sbYqZ9xPmxdVtBnCpr9X7DQ==
  -----END CERTIFICATE-----
  """

  @key_pem """
  -----BEGIN PRIVATE KEY-----
  MIGHAgEAMBMGByqGSM49AgEGCCqGSM49AwEHBG0wawIBAQQgRBg94MH44d4RiAnf
  ++E4pYP04y9GdBtLMsvOwCS10iChRANCAASQbwr168E5NN7/m+yFh9pIse10XfPv
  bn9Vw0EU8xRfhLcW20dxFoBC7xF4GbcxtrBKAr23FbDMjikhZTmO6utw
  -----END PRIVATE KEY-----
  """

  describe "TLS termination" do
    test "Bandit serves the CertCache certificate via sni_fun" do
      cache_name = :"web_cert_cache_#{System.unique_integer([:positive])}"
      bandit_name = :"bandit_web_#{System.unique_integer([:positive])}"

      start_supervised!(
        {CertCache, name: cache_name, fetch_fn: fn -> {:ok, @cert_pem, @key_pem} end}
      )

      [cert: [expected_cert_der], key: _] = CertCache.get_opts(cache_name)

      start_supervised!(
        {Bandit,
         plug: PortalWeb.Endpoint,
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
