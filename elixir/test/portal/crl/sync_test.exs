defmodule Portal.Crl.SyncTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures
  import Portal.TrustAnchorFixtures
  import Portal.FeaturesFixtures
  import Portal.DeviceTrustFixtures
  import ExUnit.CaptureLog

  alias Portal.Crl.Sync
  alias Portal.Crypto.X509

  @crl_url "http://crl.example.test/ca.crl"
  @mirror_url "http://mirror.example.test/ca.crl"
  @delta_url "http://crl.example.test/delta.crl"

  setup do
    account = account_fixture()
    enable_feature(:device_trust)
    pki = pki()
    trust_anchor_fixture(account: account, certs: [pki.ca_der])

    %{account: account, pki: pki}
  end

  describe "perform/1" do
    test "caches every serial the CRL revokes", %{account: account, pki: pki} do
      leaf = leaf(pki, :rsa)
      endpoint = endpoint_fixture(account, pki.ca_der)
      stub_crl(crl(pki.ca, revoked: [leaf], number: 9))

      assert perform(endpoint) == {:ok, :refreshed}

      assert [revocation] = Repo.all(Portal.CrlRevocation)
      assert revocation.issuer == X509.issuer(leaf)
      assert revocation.serial == cert_serial_hex(leaf)

      assert Repo.one!(Portal.RevocationEndpoint).crl_number == 9
      assert is_nil(Repo.one!(Portal.RevocationEndpoint).crl_error)
    end

    test "replaces the previous set rather than merging into it", %{account: account, pki: pki} do
      first = leaf(pki, :rsa)
      second = leaf(pki, :ec)
      endpoint = endpoint_fixture(account, pki.ca_der)

      stub_crl(crl(pki.ca, revoked: [first]))
      assert perform(endpoint) == {:ok, :refreshed}

      stub_crl(crl(pki.ca, revoked: [second], number: 2))
      assert perform(endpoint) == {:ok, :refreshed}

      assert [revocation] = Repo.all(Portal.CrlRevocation)
      assert revocation.serial == cert_serial_hex(second)
    end

    test "verifies against the anchor bearing the issuer's name", %{account: account, pki: pki} do
      # Both the root and its intermediate are uploaded, so a leaf validates
      # against either. Only the intermediate signs the list covering it.
      trust_anchor_fixture(account: account, certs: [pki.intermediate_der])
      leaf = leaf(pki, :via_intermediate)
      endpoint = endpoint_fixture(account, pki.intermediate_der)
      stub_crl(crl(pki.intermediate, revoked: [leaf]))

      assert perform(endpoint) == {:ok, :refreshed}
      assert [revocation] = Repo.all(Portal.CrlRevocation)
      assert revocation.issuer == X509.issuer(leaf)
    end

    test "refuses a CRL signed by anyone else", %{account: account, pki: pki} do
      endpoint = endpoint_fixture(account, pki.ca_der)
      stub_crl(crl(pki.untrusted_ca, revoked: [leaf(pki, :untrusted)]))

      assert failure(endpoint) =~ "crl_issuer_mismatch"
      assert Repo.all(Portal.CrlRevocation) == []
    end

    test "refuses a CRL published by a different CA at the same address", %{
      account: account,
      pki: pki
    } do
      # The address came from a certificate, so whatever answers it has to be
      # that certificate issuer's list and not another CA's.
      trust_anchor_fixture(account: account, certs: [pki.intermediate_der])
      endpoint = endpoint_fixture(account, pki.ca_der)
      stub_crl(crl(pki.intermediate, revoked: [leaf(pki, :via_intermediate)]))

      assert failure(endpoint) =~ "crl_issuer_mismatch"
      assert Repo.all(Portal.CrlRevocation) == []
    end

    test "accepts a complete list that names the address it was fetched from", %{
      account: account,
      pki: pki
    } do
      # An Issuing Distribution Point does not make a list partial. A CA may
      # stamp one purely to name itself, and rejecting those would leave the
      # cache empty, which reads as nothing being revoked.
      leaf = leaf(pki, :rsa)
      endpoint = endpoint_fixture(account, pki.ca_der)
      stub_crl(crl(pki.ca, revoked: [leaf], idp: [distribution_point: @crl_url]))

      assert perform(endpoint) == {:ok, :refreshed}
      assert [_revocation] = Repo.all(Portal.CrlRevocation)
    end

    test "refuses a list belonging to another partition", %{account: account, pki: pki} do
      endpoint = endpoint_fixture(account, pki.ca_der)

      stub_crl(
        crl(pki.ca,
          revoked: [leaf(pki, :rsa)],
          idp: [distribution_point: "http://crl.example.test/other.crl"]
        )
      )

      assert failure(endpoint) =~ "crl_wrong_partition"
      assert Repo.all(Portal.CrlRevocation) == []
    end

    test "refuses a list scoped to CA certificates", %{account: account, pki: pki} do
      endpoint = endpoint_fixture(account, pki.ca_der)
      stub_crl(crl(pki.ca, revoked: [leaf(pki, :rsa)], idp: [only_ca_certs: true]))

      assert failure(endpoint) =~ "only_ca_certs"
      assert Repo.all(Portal.CrlRevocation) == []
    end

    test "refuses an indirect list", %{account: account, pki: pki} do
      endpoint = endpoint_fixture(account, pki.ca_der)
      stub_crl(crl(pki.ca, revoked: [leaf(pki, :rsa)], idp: [indirect: true]))

      assert failure(endpoint) =~ "indirect"
      assert Repo.all(Portal.CrlRevocation) == []
    end

    test "replaces only its own partition", %{account: account, pki: pki} do
      other = leaf(pki, :ec)

      Repo.insert!(%Portal.CrlRevocation{
        account_id: account.id,
        issuer: X509.subject(pki.ca_der),
        distribution_point: "http://crl.example.test/other.crl",
        serial: cert_serial_hex(other),
        revoked_at: DateTime.utc_now() |> DateTime.truncate(:second),
        inserted_at: DateTime.utc_now()
      })

      endpoint = endpoint_fixture(account, pki.ca_der)
      stub_crl(crl(pki.ca, revoked: [leaf(pki, :rsa)]))

      assert perform(endpoint) == {:ok, :refreshed}

      # The other partition's entry survives; replacing per issuer would have
      # wiped a list this fetch never saw.
      assert Repo.aggregate(Portal.CrlRevocation, :count) == 2
    end

    test "falls over to the next address when the first does not answer", %{
      account: account,
      pki: pki
    } do
      leaf = leaf(pki, :rsa)
      endpoint = endpoint_fixture(account, pki.ca_der, crl_urls: [@crl_url, @mirror_url])
      body = crl(pki.ca, revoked: [leaf])

      Req.Test.stub(Sync, fn conn ->
        if conn.host == "crl.example.test" do
          Req.Test.transport_error(conn, :econnrefused)
        else
          Plug.Conn.send_resp(conn, 200, body)
        end
      end)

      assert perform(endpoint) == {:ok, :refreshed}
      assert [_revocation] = Repo.all(Portal.CrlRevocation)
    end

    test "stops at the first address when the list itself is unusable", %{
      account: account,
      pki: pki
    } do
      endpoint = endpoint_fixture(account, pki.ca_der, crl_urls: [@crl_url, @mirror_url])
      stub_crl(crl(pki.untrusted_ca, revoked: [leaf(pki, :untrusted)]))

      # Alternates serve the same bytes, so a rejected list is rejected at all
      # of them and trying the rest would just fetch it again.
      assert failure(endpoint) =~ "crl_issuer_mismatch"
    end

    test "names an address it cannot speak instead of reporting a fetch failure", %{
      account: account,
      pki: pki
    } do
      endpoint = endpoint_fixture(account, pki.ca_der, crl_urls: ["ldap://dc.corp.test/CN=CA"])

      assert failure(endpoint) =~ "unsupported_url_scheme"
    end

    test "keeps the cached list when the CA is unreachable", %{account: account, pki: pki} do
      leaf = leaf(pki, :rsa)
      endpoint = endpoint_fixture(account, pki.ca_der)

      stub_crl(crl(pki.ca, revoked: [leaf]))
      assert perform(endpoint) == {:ok, :refreshed}

      Req.Test.stub(Sync, fn conn -> Req.Test.transport_error(conn, :econnrefused) end)
      assert failure(endpoint) =~ "connection refused"

      assert [revocation] = Repo.all(Portal.CrlRevocation)
      assert revocation.serial == cert_serial_hex(leaf)
    end

    test "refuses a body that is not a CRL at all", %{account: account, pki: pki} do
      endpoint = endpoint_fixture(account, pki.ca_der)
      stub_crl("not a crl")

      assert failure(endpoint) =~ "crl_issuer_mismatch"
    end

    test "notifies the session of a certificate that has just been revoked", %{
      account: account,
      pki: pki
    } do
      leaf = leaf(pki, :rsa)
      device = attested_device(account, pki, leaf)
      endpoint = endpoint_fixture(account, pki.ca_der)
      issuer = X509.subject(pki.ca_der)
      serial = cert_serial_hex(leaf)

      Portal.PG.register(device.id)
      stub_crl(crl(pki.ca, revoked: [leaf]))

      assert perform(endpoint) == {:ok, :refreshed}

      # Named rather than acted on: the device columns record the last
      # certificate a device ever presented, so only the session knows whether
      # this revocation is about the certificate it is actually using.
      assert_receive {:certificate_revoked, ^issuer, ^serial}
    end

    test "leaves a device holding the same serial from another CA alone", %{
      account: account,
      pki: pki
    } do
      leaf = leaf(pki, :rsa)
      device = attested_device(account, pki, leaf, issuer_der: pki.untrusted_ca_der)
      endpoint = endpoint_fixture(account, pki.ca_der)

      Portal.PG.register(device.id)
      stub_crl(crl(pki.ca, revoked: [leaf]))

      assert perform(endpoint) == {:ok, :refreshed}
      refute_receive {:certificate_revoked, _issuer, _serial}
    end

    test "does not notify again for a serial already cached", %{account: account, pki: pki} do
      leaf = leaf(pki, :rsa)
      device = attested_device(account, pki, leaf)
      endpoint = endpoint_fixture(account, pki.ca_der)

      stub_crl(crl(pki.ca, revoked: [leaf]))
      assert perform(endpoint) == {:ok, :refreshed}

      Portal.PG.register(device.id)
      stub_crl(crl(pki.ca, revoked: [leaf], number: 2))

      assert perform(endpoint) == {:ok, :refreshed}
      refute_receive {:certificate_revoked, _issuer, _serial}
    end

    test "applies the delta on top of the complete list", %{account: account, pki: pki} do
      on_list = leaf(pki, :rsa)
      on_delta = leaf(pki, :ec)
      endpoint = endpoint_fixture(account, pki.ca_der)

      stub_paths(%{
        "/ca.crl" => crl(pki.ca, revoked: [on_list], number: 9, freshest: @delta_url),
        "/delta.crl" => crl(pki.ca, revoked: [on_delta], number: 10, delta: 9)
      })

      assert perform(endpoint) == {:ok, :refreshed}

      assert revoked_serials() ==
               MapSet.new([cert_serial_hex(on_list), cert_serial_hex(on_delta)])

      refreshed = Repo.one!(Portal.RevocationEndpoint)
      assert refreshed.delta_number == 10
      assert refreshed.delta_next_update
      assert is_nil(refreshed.delta_error)
    end

    test "un-revokes a certificate the delta takes off the list", %{account: account, pki: pki} do
      released = leaf(pki, :rsa)
      still_revoked = leaf(pki, :ec)
      endpoint = endpoint_fixture(account, pki.ca_der)

      stub_paths(%{
        "/ca.crl" =>
          crl(pki.ca, revoked: [released, still_revoked], number: 9, freshest: @delta_url),
        "/delta.crl" => crl(pki.ca, removed: [released], number: 10, delta: 9)
      })

      assert perform(endpoint) == {:ok, :refreshed}

      # CRLReason removeFromCRL says the certificate is revoked no longer, so
      # the serial has to leave the cache rather than be listed with a reason.
      assert revoked_serials() == MapSet.new([cert_serial_hex(still_revoked)])
    end

    test "accepts a delta scoped to the address of the list it applies to", %{
      account: account,
      pki: pki
    } do
      on_delta = leaf(pki, :ec)
      endpoint = endpoint_fixture(account, pki.ca_der)

      stub_paths(%{
        "/ca.crl" => crl(pki.ca, number: 9, freshest: @delta_url),
        "/delta.crl" =>
          crl(pki.ca,
            revoked: [on_delta],
            number: 10,
            delta: 9,
            idp: [distribution_point: @crl_url]
          )
      })

      assert perform(endpoint) == {:ok, :refreshed}
      assert revoked_serials() == MapSet.new([cert_serial_hex(on_delta)])
    end

    test "refuses a delta built on a newer list than the one it was served with", %{
      account: account,
      pki: pki
    } do
      on_list = leaf(pki, :rsa)
      on_delta = leaf(pki, :ec)
      endpoint = endpoint_fixture(account, pki.ca_der)

      stub_paths(%{
        "/ca.crl" => crl(pki.ca, revoked: [on_list], number: 9, freshest: @delta_url),
        "/delta.crl" => crl(pki.ca, revoked: [on_delta], number: 11, delta: 10)
      })

      assert perform(endpoint) == {:ok, :refreshed}

      assert revoked_serials() == MapSet.new([cert_serial_hex(on_list)])
      assert Repo.one!(Portal.RevocationEndpoint).delta_error =~ "delta_base_too_new"
    end

    test "refuses a complete list served at the delta's address", %{account: account, pki: pki} do
      on_list = leaf(pki, :rsa)
      endpoint = endpoint_fixture(account, pki.ca_der)

      stub_paths(%{
        "/ca.crl" => crl(pki.ca, revoked: [on_list], number: 9, freshest: @delta_url),
        "/delta.crl" => crl(pki.ca, revoked: [leaf(pki, :ec)], number: 10)
      })

      assert perform(endpoint) == {:ok, :refreshed}

      assert revoked_serials() == MapSet.new([cert_serial_hex(on_list)])
      assert Repo.one!(Portal.RevocationEndpoint).delta_error =~ "crl_not_delta"
    end

    test "refuses a delta served at the complete list's address", %{account: account, pki: pki} do
      endpoint = endpoint_fixture(account, pki.ca_der)
      stub_crl(crl(pki.ca, revoked: [leaf(pki, :rsa)], delta: 1))

      # A delta lists only what changed, so caching it as the whole set would
      # drop every serial the complete list carries.
      assert failure(endpoint) =~ "crl_is_delta"
      assert Repo.all(Portal.CrlRevocation) == []
    end

    test "keeps the complete list when the delta cannot be fetched", %{
      account: account,
      pki: pki
    } do
      on_list = leaf(pki, :rsa)
      endpoint = endpoint_fixture(account, pki.ca_der)

      stub_paths(%{"/ca.crl" => crl(pki.ca, revoked: [on_list], number: 9, freshest: @delta_url)})

      assert perform(endpoint) == {:ok, :refreshed}

      assert revoked_serials() == MapSet.new([cert_serial_hex(on_list)])

      refreshed = Repo.one!(Portal.RevocationEndpoint)
      assert refreshed.delta_error =~ "connection refused"
      assert is_nil(refreshed.crl_error)
      assert refreshed.crl_number == 9
    end

    test "forgets the delta once the list stops naming one", %{account: account, pki: pki} do
      endpoint = endpoint_fixture(account, pki.ca_der)

      stub_paths(%{
        "/ca.crl" => crl(pki.ca, number: 9, freshest: @delta_url),
        "/delta.crl" => crl(pki.ca, revoked: [leaf(pki, :ec)], number: 10, delta: 9)
      })

      assert perform(endpoint) == {:ok, :refreshed}
      assert Repo.one!(Portal.RevocationEndpoint).delta_number == 10

      stub_paths(%{"/ca.crl" => crl(pki.ca, number: 11)})

      assert perform(endpoint) == {:ok, :refreshed}

      refreshed = Repo.one!(Portal.RevocationEndpoint)
      assert is_nil(refreshed.delta_number)
      assert is_nil(refreshed.delta_next_update)
      assert is_nil(refreshed.delta_error)
    end

    test "keeps a delta's revocations when the delta cannot be refetched", %{
      account: account,
      pki: pki
    } do
      base_only = leaf(pki, :rsa)
      delta_only = leaf(pki, :ec)
      endpoint = endpoint_fixture(account, pki.ca_der)

      base = crl(pki.ca, revoked: [base_only], number: 5, freshest: @delta_url)
      stub_paths(%{
        "/ca.crl" => base,
        "/delta.crl" => crl(pki.ca, revoked: [delta_only], number: 6, delta: 5)
      })
      assert perform(endpoint) == {:ok, :refreshed}
      assert Repo.aggregate(Portal.CrlRevocation, :count) == 2

      # The base has not moved, so it does not carry what the delta added. If the
      # delta cannot be read this run, replacing from the base alone would
      # silently un-revoke the certificate only the delta listed.
      stub_paths(%{"/ca.crl" => base})

      assert capture_log(fn -> assert perform(endpoint) == {:ok, :refreshed} end) =~
               "Keeping the cached revocation list"

      assert Repo.aggregate(Portal.CrlRevocation, :count) == 2
      assert Repo.one!(Portal.RevocationEndpoint).delta_error
    end

    test "refuses a delta older than the list it sits on", %{account: account, pki: pki} do
      endpoint = endpoint_fixture(account, pki.ca_der)

      base = crl(pki.ca, revoked: [leaf(pki, :rsa)], number: 11, freshest: @delta_url)

      stub_paths(%{
        "/ca.crl" => base,
        "/delta.crl" => crl(pki.ca, revoked: [leaf(pki, :ec)], number: 10, delta: 9)
      })

      # Numbered below the base, so it predates it: applying it would reintroduce
      # what the newer base already superseded.
      assert perform(endpoint) == {:ok, :refreshed}
      assert Repo.aggregate(Portal.CrlRevocation, :count) == 1
      assert Repo.one!(Portal.RevocationEndpoint).delta_error =~ "delta_not_newer"
    end

    test "refuses a list older than the one already cached", %{account: account, pki: pki} do
      first = leaf(pki, :rsa)
      second = leaf(pki, :ec)
      endpoint = endpoint_fixture(account, pki.ca_der)

      stub_crl(crl(pki.ca, revoked: [first, second], number: 9))
      assert perform(endpoint) == {:ok, :refreshed}

      # A stale mirror, or a replayed response, would otherwise roll the cache
      # back and un-revoke whatever the newer list had added.
      stub_crl(crl(pki.ca, revoked: [first], number: 8))

      assert failure(endpoint) =~ "crl_rolled_back"
      assert Repo.aggregate(Portal.CrlRevocation, :count) == 2
    end

    test "refuses a list that has already expired", %{account: account, pki: pki} do
      endpoint = endpoint_fixture(account, pki.ca_der)
      stub_crl(crl(pki.ca, revoked: [leaf(pki, :rsa)], validity: {-30, -1}))

      assert failure(endpoint) =~ "crl_expired"
      assert Repo.all(Portal.CrlRevocation) == []
    end

    test "does nothing when the endpoint is gone", %{account: account, pki: pki} do
      endpoint = endpoint_fixture(account, pki.ca_der)
      Repo.delete_all(Portal.RevocationEndpoint)

      assert perform(endpoint) == {:ok, :deleted}
    end
  end

  describe "perform/1 when the endpoint keeps failing" do
    test "an address we will never reach stops the fetching at once", %{
      account: account,
      pki: pki
    } do
      endpoint = endpoint_fixture(account, pki.ca_der, crl_urls: ["ldap://crl.example.test/ca"])

      failure(endpoint)

      endpoint = Repo.one!(Portal.RevocationEndpoint)
      assert endpoint.is_disabled
      assert endpoint.disabled_reason == Portal.Revocation.Failure.disabled_reason()
      assert endpoint.errored_at
    end

    test "a timeout only starts the clock", %{account: account, pki: pki} do
      endpoint = endpoint_fixture(account, pki.ca_der)
      Req.Test.stub(Sync, fn conn -> Req.Test.transport_error(conn, :timeout) end)

      failure(endpoint)

      endpoint = Repo.one!(Portal.RevocationEndpoint)
      refute endpoint.is_disabled
      assert endpoint.errored_at
    end

    test "a day of timeouts stops the fetching", %{account: account, pki: pki} do
      endpoint = endpoint_fixture(account, pki.ca_der)
      Req.Test.stub(Sync, fn conn -> Req.Test.transport_error(conn, :timeout) end)

      failure(endpoint)

      started = DateTime.add(DateTime.utc_now(), -25, :hour)
      Repo.update_all(Portal.RevocationEndpoint, set: [errored_at: started])

      failure(endpoint)

      endpoint = Repo.one!(Portal.RevocationEndpoint)
      assert endpoint.is_disabled
      assert endpoint.errored_at == started
    end

    test "a list that comes back clears the streak", %{account: account, pki: pki} do
      endpoint = endpoint_fixture(account, pki.ca_der)
      Req.Test.stub(Sync, fn conn -> Req.Test.transport_error(conn, :timeout) end)
      failure(endpoint)

      stub_crl(crl(pki.ca, revoked: []))
      assert perform(endpoint) == {:ok, :refreshed}

      endpoint = Repo.one!(Portal.RevocationEndpoint)
      assert is_nil(endpoint.errored_at)
      assert is_nil(endpoint.crl_error)
    end

    test "a disabled endpoint is never scheduled again", %{account: account, pki: pki} do
      endpoint_fixture(account, pki.ca_der)
      Repo.update_all(Portal.RevocationEndpoint, set: [is_disabled: true])

      assert {:ok, :scheduled} = Portal.Crl.Scheduler.perform(%Oban.Job{args: %{}})

      assert [] = all_enqueued(worker: Sync)
    end
  end

  defp perform(endpoint) do
    Sync.perform(%Oban.Job{
      args: %{
        "account_id" => endpoint.account_id,
        "issuer" => Base.encode64(endpoint.issuer),
        "distribution_point" => endpoint.distribution_point
      }
    })
  end

  defp failure(endpoint) do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert perform(endpoint) == {:ok, :failed}
      end)

    assert Repo.one!(Portal.RevocationEndpoint).crl_error
    log
  end

  defp attested_device(account, pki, leaf, attrs \\ []) do
    issuer_der = Keyword.get(attrs, :issuer_der, pki.ca_der)
    token = Portal.TokenFixtures.client_token_fixture(account: account)

    Portal.DeviceFixtures.client_fixture(
      account: account,
      last_attested_cert_issuer: X509.subject(issuer_der),
      last_attested_cert_serial: cert_serial_hex(leaf)
    )
    |> Ecto.Changeset.change(client_token_id: token.id)
    |> Repo.update!()
  end

  defp endpoint_fixture(account, issuer_der, attrs \\ []) do
    issuer = X509.subject(issuer_der)
    crl_urls = Keyword.get(attrs, :crl_urls, [@crl_url])

    Repo.insert!(%Portal.RevocationEndpoint{
      account_id: account.id,
      issuer: issuer,
      distribution_point: Keyword.get(attrs, :distribution_point, List.first(crl_urls)),
      crl_urls: crl_urls,
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    })
  end

  defp stub_crl(body) do
    Req.Test.stub(Sync, fn conn -> Plug.Conn.send_resp(conn, 200, body) end)
  end

  # A CA serves its complete list and the delta on top of it from the same host,
  # so the two are told apart by path.
  defp stub_paths(bodies) do
    Req.Test.stub(Sync, fn conn ->
      case Map.fetch(bodies, conn.request_path) do
        {:ok, body} -> Plug.Conn.send_resp(conn, 200, body)
        :error -> Req.Test.transport_error(conn, :econnrefused)
      end
    end)
  end

  defp revoked_serials do
    Portal.CrlRevocation |> Repo.all() |> MapSet.new(& &1.serial)
  end

  defp cert_serial_hex(der) do
    {:Certificate, tbs, _algorithm, _signature} = :public_key.der_decode(:Certificate, der)

    tbs |> elem(2) |> Integer.to_string(16)
  end
end
