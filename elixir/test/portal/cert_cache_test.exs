defmodule Portal.CertCacheTest do
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

  @cert_pem2 """
  -----BEGIN CERTIFICATE-----
  MIIBdTCCARugAwIBAgIUbqSUm+VLjcZF0Npui2DsOmyqyQ4wCgYIKoZIzj0EAwIw
  EDEOMAwGA1UEAwwFdGVzdDIwHhcNMjYwMzI4MTMyMzQ1WhcNMzYwMzI1MTMyMzQ1
  WjAQMQ4wDAYDVQQDDAV0ZXN0MjBZMBMGByqGSM49AgEGCCqGSM49AwEHA0IABGdT
  o2wiT1ej6LJstVQTlcceOQk0VzKCWrqtxCzD4VQimKTSpr4EOXxnheQgUcAkMo1z
  oHxfxalPtzQI986+Vg6jUzBRMB0GA1UdDgQWBBS3OEXO4la3zYAesGfayd62bSVb
  VTAfBgNVHSMEGDAWgBS3OEXO4la3zYAesGfayd62bSVbVTAPBgNVHRMBAf8EBTAD
  AQH/MAoGCCqGSM49BAMCA0gAMEUCIQDz1xaLHOx9l8LztwjgZ0rQ/qnFpcpcqwPT
  N7pO7V0ecgIgUozivvyVdE1SVal9iRYc+5NaILMA3PppHur3CmoGOnM=
  -----END CERTIFICATE-----
  """

  defp unique_name do
    :"cert_cache_#{System.unique_integer([:positive])}"
  end

  describe "parse_pem/2" do
    test "parses a certificate and key from PEM" do
      assert [cert: [cert_der], key: {:PrivateKeyInfo, key_der}] =
               CertCache.parse_pem(@cert_pem, @key_pem)

      assert is_binary(cert_der)
      assert is_binary(key_der)
    end

    test "parses multiple certificates in a chain" do
      chain_pem = @cert_pem <> @cert_pem2

      assert [cert: [_, _], key: {_, _}] = CertCache.parse_pem(chain_pem, @key_pem)
    end
  end

  describe "init and get_opts/1" do
    test "populates state on init" do
      name = unique_name()

      start_supervised!({CertCache, name: name, fetch_fn: fn -> {:ok, @cert_pem, @key_pem} end})

      assert [cert: [_ | _], key: {_, _}] = CertCache.get_opts(name)
    end

    test "fails to start if fetch_fn returns error" do
      name = unique_name()

      assert {:error, _} =
               start_supervised({CertCache, name: name, fetch_fn: fn -> {:error, :boom} end})
    end

    test "fails to start if fetch_fn raises" do
      name = unique_name()

      assert {:error, _} =
               start_supervised({CertCache, name: name, fetch_fn: fn -> raise "kaboom" end})
    end

    test "fails to start if PEM contains no certificate" do
      name = unique_name()

      assert {:error, _} =
               start_supervised({CertCache, name: name, fetch_fn: fn -> {:ok, "", @key_pem} end})
    end

    test "fails to start if PEM contains no private key" do
      name = unique_name()

      assert {:error, _} =
               start_supervised({CertCache, name: name, fetch_fn: fn -> {:ok, @cert_pem, ""} end})
    end
  end

  describe "refresh/1" do
    test "updates state on refresh" do
      name = unique_name()
      call_count = :counters.new(1, [:atomics])

      start_supervised!(
        {CertCache,
         name: name,
         fetch_fn: fn ->
           :counters.add(call_count, 1, 1)

           if :counters.get(call_count, 1) > 1 do
             {:ok, @cert_pem <> @cert_pem2, @key_pem}
           else
             {:ok, @cert_pem, @key_pem}
           end
         end}
      )

      assert [cert: [_single], key: _] = CertCache.get_opts(name)

      CertCache.refresh(name)
      Process.sleep(50)

      assert [cert: [_, _], key: _] = CertCache.get_opts(name)
    end

    test "keeps stale cert on refresh failure" do
      name = unique_name()
      call_count = :counters.new(1, [:atomics])

      start_supervised!(
        {CertCache,
         name: name,
         fetch_fn: fn ->
           :counters.add(call_count, 1, 1)

           if :counters.get(call_count, 1) > 1 do
             {:error, :simulated_failure}
           else
             {:ok, @cert_pem, @key_pem}
           end
         end}
      )

      original_opts = CertCache.get_opts(name)

      CertCache.refresh(name)
      Process.sleep(50)

      assert CertCache.get_opts(name) == original_opts
    end
  end
end
