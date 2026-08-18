defmodule PortalWeb.Settings.TrustAnchors.IndexTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.TrustAnchorFixtures
  import Portal.FeaturesFixtures

  alias Portal.TrustAnchor
  alias Portal.Crypto.X509

  defp certificate_der(certificate) do
    {:ok, [{_type, der, _headers}]} = X509.pem_decode(certificate.pem)
    der
  end

  defp endpoint_fixture(account, issuer, attrs \\ []) do
    Repo.insert!(%Portal.RevocationEndpoint{
      account_id: account.id,
      issuer: issuer,
      distribution_point: "http://crl.test.invalid/ec-ca.crl",
      crl_urls: Keyword.get(attrs, :crl_urls, ["http://crl.test.invalid/ec-ca.crl"]),
      crl_number: Keyword.get(attrs, :crl_number),
      crl_error: Keyword.get(attrs, :crl_error),
      inserted_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    })
  end

  defp open_certificates_tab(lv) do
    render_click(lv, "switch_anchor_tab", %{"tab" => "certificates"})
  end

  defp open_revocation_tab(lv) do
    render_click(lv, "switch_anchor_tab", %{"tab" => "revocation"})
  end

  defp expand_first_endpoint(lv) do
    lv |> element("tr[phx-click='toggle_revocation_endpoint']") |> render_click()
  end

  defp timestamp_popovers(html) do
    html
    |> Floki.parse_fragment!()
    |> Floki.find("[role='tooltip']")
    |> Enum.map(&(Floki.text(&1) |> String.trim()))
  end

  defp assert_timestamp_popover(popovers, datetime) do
    assert DateTime.to_iso8601(datetime) in popovers
  end

  defp revocation_fixture(account, issuer, serial) do
    Repo.insert!(%Portal.CrlRevocation{
      account_id: account.id,
      issuer: issuer,
      distribution_point: "http://crl.test.invalid/ec-ca.crl",
      serial: serial,
      revoked_at: DateTime.utc_now() |> DateTime.truncate(:second),
      inserted_at: DateTime.utc_now()
    })
  end

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)
    enable_feature(:trust_anchors)
    %{account: account, actor: actor}
  end

  describe "unauthorized" do
    test "redirects to sign-in when not authenticated", %{conn: conn, account: account} do
      path = ~p"/#{account}/settings/trust_anchors"

      assert live(conn, path) ==
               {:error,
                {:redirect,
                 %{
                   to: ~p"/#{account}/sign_in?#{%{redirect_to: path}}",
                   flash: %{"error" => "You must sign in to access that page."}
                 }}}
    end
  end

  describe "index (default action)" do
    test "redirects to account settings when trust_anchors feature is disabled", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      disable_feature(:trust_anchors)

      assert {:error, {:live_redirect, %{to: to}}} =
               conn
               |> authorize_conn(actor)
               |> live(~p"/#{account}/settings/trust_anchors")

      assert to == ~p"/#{account}/settings/account"
    end

    test "renders empty state when no trust anchors", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/trust_anchors")

      assert html =~ "Trust Anchors"
      assert html =~ "No trust anchors yet"
    end

    test "renders trust anchor rows", %{conn: conn, account: account, actor: actor} do
      trust_anchor_fixture(account: account, name: "Corporate Issuing CA")

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/trust_anchors")

      assert html =~ "Corporate Issuing CA"
      assert html =~ "1 certificate"
    end

    test "shows created timestamps with their raw values in popovers", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      inserted_at = ~U[2026-01-02 03:04:05.123456Z]

      trust_anchor =
        trust_anchor_fixture(account: account, name: "Corporate Issuing CA")
        |> Ecto.Changeset.change(inserted_at: inserted_at)
        |> Repo.update!()

      conn = authorize_conn(conn, actor)

      {:ok, _lv, index_html} =
        conn
        |> live(~p"/#{account}/settings/trust_anchors")

      assert timestamp_popovers(index_html) == [DateTime.to_iso8601(inserted_at)]

      {:ok, _lv, show_html} =
        conn
        |> live(~p"/#{account}/settings/trust_anchors/#{trust_anchor.id}")

      assert timestamp_popovers(show_html) == [
               DateTime.to_iso8601(inserted_at),
               DateTime.to_iso8601(inserted_at)
             ]
    end
  end

  describe "show panel" do
    test "opens the show panel when a row is clicked and closes it", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      trust_anchor =
        trust_anchor_fixture(
          account: account,
          name: "Corporate Issuing CA",
          certs: [sample_cert_der()]
        )

      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/trust_anchors")

      refute html =~ "Company Issuing CA"

      html =
        lv
        |> element("tr[phx-click='select_trust_anchor'][phx-value-id='#{trust_anchor.id}']")
        |> render_click()

      assert_patch(lv, ~p"/#{account}/settings/trust_anchors/#{trust_anchor.id}")
      refute html =~ "Company Issuing CA"

      html = open_certificates_tab(lv)
      assert html =~ "Company Issuing CA"
      assert html =~ "Company Root CA"
      assert html =~ Base.encode16(:crypto.hash(:sha256, sample_cert_der()), case: :lower)

      render_click(lv, "close_panel")
      assert_patch(lv, ~p"/#{account}/settings/trust_anchors")
      refute render(lv) =~ "Company Issuing CA"
    end

    test "shows comprehensive certificate details and a PEM download link", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      trust_anchor =
        trust_anchor_fixture(
          account: account,
          name: "EC Anchor",
          certs: [sample_ec_ca_der()]
        )

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/trust_anchors/#{trust_anchor.id}")

      html = open_certificates_tab(lv)

      assert html =~ "CN=EC Trust Anchor CA"
      assert html =~ "ecdsa-with-SHA256"
      assert html =~ "ECDSA P-256 (256-bit)"
      assert html =~ "CA:TRUE, pathlen:1"
      assert html =~ "digitalSignature, keyCertSign, cRLSign"
      assert html =~ "TLS Client Authentication, TLS Server Authentication"
      assert html =~ "DNS:ca.test.invalid, IP:10.0.0.1"
      assert html =~ "http://crl.test.invalid/ec-ca.crl"
      assert html =~ "http://ocsp.test.invalid"
      assert html =~ "http://ca.test.invalid/root.cer"

      {:ok, certificate} = X509.decode_der_certificate(sample_ec_ca_der())
      popovers = timestamp_popovers(html)
      assert_timestamp_popover(popovers, X509.not_before(certificate))
      assert_timestamp_popover(popovers, X509.not_after(certificate))

      assert [download_link] =
               html
               |> Floki.parse_fragment!()
               |> Floki.find("a[download]")

      assert [href] = Floki.attribute(download_link, "href")
      assert "data:application/x-pem-file;base64," <> encoded = href
      assert {:ok, [{:Certificate, der, :not_encrypted}]} =
               encoded |> Base.decode64!() |> X509.pem_decode()

      assert der == sample_ec_ca_der()
    end

    test "closes the show panel on escape", %{conn: conn, account: account, actor: actor} do
      trust_anchor = trust_anchor_fixture(account: account, name: "Corporate Issuing CA")

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/trust_anchors/#{trust_anchor.id}")

      render_keydown(lv, "handle_keydown", %{"key" => "Escape"})
      assert_patch(lv, ~p"/#{account}/settings/trust_anchors")
    end

    test "Edit button navigates to the edit form", %{conn: conn, account: account, actor: actor} do
      trust_anchor = trust_anchor_fixture(account: account, name: "Corporate Issuing CA")

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/trust_anchors/#{trust_anchor.id}")

      lv
      |> element(
        "a[href='#{~p"/#{account}/settings/trust_anchors/#{trust_anchor.id}/edit"}']"
      )
      |> render_click()

      assert_patch(lv, ~p"/#{account}/settings/trust_anchors/#{trust_anchor.id}/edit")
      assert render(lv) =~ "Edit Trust Anchor"
    end
  end

  describe "revocation section" do
    setup %{account: account} do
      trust_anchor =
        trust_anchor_fixture(account: account, name: "EC Anchor", certs: [sample_ec_ca_der()])

      %{trust_anchor: trust_anchor, issuer: X509.subject(sample_ec_ca_der())}
    end

    test "says nothing is known before a device has connected", %{
      conn: conn,
      account: account,
      actor: actor,
      trust_anchor: trust_anchor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/trust_anchors/#{trust_anchor.id}")

      assert open_revocation_tab(lv) =~ "No revocation endpoint known yet"
    end

    test "shows the endpoint learned for the issuer", %{
      conn: conn,
      account: account,
      actor: actor,
      trust_anchor: trust_anchor,
      issuer: issuer
    } do
      endpoint_fixture(account, issuer, crl_number: 42)
      revocation_fixture(account, issuer, "AABBCC")

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/trust_anchors/#{trust_anchor.id}")

      assert open_revocation_tab(lv) =~ "CN=EC Trust Anchor CA"

      html = expand_first_endpoint(lv)
      assert html =~ "http://crl.test.invalid/ec-ca.crl"
      assert html =~ "Revoked certificates"
      assert html =~ "CRL number"
      assert html =~ "42"
    end

    test "surfaces the last failure", %{
      conn: conn,
      account: account,
      actor: actor,
      trust_anchor: trust_anchor,
      issuer: issuer
    } do
      endpoint_fixture(account, issuer, crl_error: "unsupported_url_scheme")

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/trust_anchors/#{trust_anchor.id}")

      open_revocation_tab(lv)
      assert expand_first_endpoint(lv) =~ "unsupported_url_scheme"
    end

    test "shows revocation timestamps with their raw values in popovers", %{
      conn: conn,
      account: account,
      actor: actor,
      trust_anchor: trust_anchor,
      issuer: issuer
    } do
      timestamps = %{
        inserted_at: ~U[2026-01-02 03:04:05.100001Z],
        errored_at: ~U[2026-01-03 03:04:05.100002Z],
        crl_fetched_at: ~U[2026-01-04 03:04:05.100003Z],
        crl_this_update: ~U[2026-01-05 03:04:05Z],
        crl_next_update: ~U[2026-01-06 03:04:05Z],
        delta_fetched_at: ~U[2026-01-07 03:04:05.100004Z],
        delta_this_update: ~U[2026-01-08 03:04:05Z],
        delta_next_update: ~U[2026-01-09 03:04:05Z],
        ocsp_checked_at: ~U[2026-01-10 03:04:05.100005Z]
      }

      endpoint_fixture(account, issuer)
      |> Ecto.Changeset.change(Map.put(timestamps, :ocsp_urls, ["http://ocsp.test.invalid"]))
      |> Repo.update!()

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/trust_anchors/#{trust_anchor.id}")

      open_revocation_tab(lv)
      popovers = lv |> expand_first_endpoint() |> timestamp_popovers()

      Enum.each(timestamps, fn {_field, datetime} ->
        assert_timestamp_popover(popovers, datetime)
      end)
    end

    test "shows OCSP state for a CA that publishes no fetchable list", %{
      conn: conn,
      account: account,
      actor: actor,
      trust_anchor: trust_anchor,
      issuer: issuer
    } do
      # An ldap:// distribution point is a list we can never read, so the issuer
      # is checked through its responder and the panel has to say so.
      Repo.insert!(%Portal.RevocationEndpoint{
        account_id: account.id,
        issuer: issuer,
        distribution_point: "http://ocsp.test.invalid",
        crl_urls: ["ldap://dc.corp.test/CN=CA"],
        ocsp_urls: ["http://ocsp.test.invalid"],
        ocsp_checked_at: DateTime.utc_now(),
        ocsp_error: "unreachable responder",
        inserted_at: DateTime.utc_now(),
        updated_at: DateTime.utc_now()
      })

      Repo.insert!(%Portal.OcspStatus{
        account_id: account.id,
        issuer: issuer,
        serial: "AABBCC",
        status: "revoked",
        updated_at: DateTime.utc_now()
      })

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/trust_anchors/#{trust_anchor.id}")

      assert open_revocation_tab(lv) =~ "OCSP"

      html = expand_first_endpoint(lv)
      assert html =~ "unreachable responder"
      assert html =~ "Revoked certificates"
      refute html =~ "CRL number"
    end

    test "an endpoint from another account is never shown", %{
      conn: conn,
      account: account,
      actor: actor,
      trust_anchor: trust_anchor,
      issuer: issuer
    } do
      endpoint_fixture(account_fixture(), issuer)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/trust_anchors/#{trust_anchor.id}")

      assert open_revocation_tab(lv) =~ "No revocation endpoint known yet"
    end
  end

  describe "revocation failures" do
    setup %{account: account} do
      trust_anchor =
        trust_anchor_fixture(account: account, name: "EC Anchor", certs: [sample_ec_ca_der()])

      %{trust_anchor: trust_anchor, issuer: X509.subject(sample_ec_ca_der())}
    end

    test "the list warns about an issuer that is still being retried", %{
      conn: conn,
      account: account,
      actor: actor,
      issuer: issuer
    } do
      endpoint_fixture(account, issuer, crl_error: "connection refused")
      |> Ecto.Changeset.change(errored_at: DateTime.utc_now())
      |> Repo.update!()

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/trust_anchors")

      assert html =~ "ri-error-warning-fill"
      assert html =~ "having trouble reaching"
    end

    test "the list says when an issuer is no longer checked at all", %{
      conn: conn,
      account: account,
      actor: actor,
      issuer: issuer
    } do
      endpoint_fixture(account, issuer, crl_error: "connection refused")
      |> Ecto.Changeset.change(
        errored_at: DateTime.utc_now(),
        is_disabled: true,
        disabled_reason: Portal.Revocation.Failure.disabled_reason()
      )
      |> Repo.update!()

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/trust_anchors")

      assert html =~ "ri-error-warning-fill"
      assert html =~ "not being checked"
    end

    test "the list says nothing about a healthy issuer", %{
      conn: conn,
      account: account,
      actor: actor,
      issuer: issuer
    } do
      endpoint_fixture(account, issuer)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/trust_anchors")

      refute html =~ "ri-error-warning-fill"
    end

    test "saving the trust anchor starts the checking again", %{
      conn: conn,
      account: account,
      actor: actor,
      trust_anchor: trust_anchor,
      issuer: issuer
    } do
      endpoint_fixture(account, issuer, crl_error: "connection refused")
      |> Ecto.Changeset.change(
        errored_at: DateTime.utc_now(),
        is_disabled: true,
        disabled_reason: Portal.Revocation.Failure.disabled_reason()
      )
      |> Repo.update!()

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/trust_anchors/#{trust_anchor.id}/edit")

      lv
      |> form("#trust-anchor-edit-form",
        trust_anchor: %{name: "EC Anchor", certs: [sample_ec_ca_pem()]}
      )
      |> render_submit()

      endpoint = Repo.one!(Portal.RevocationEndpoint)
      refute endpoint.is_disabled
      assert is_nil(endpoint.disabled_reason)
      assert is_nil(endpoint.errored_at)
      assert is_nil(endpoint.crl_error)
    end
  end

  describe ":new action" do
    test "renders create panel and closes it", %{conn: conn, account: account, actor: actor} do
      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/trust_anchors/new")

      assert html =~ "New Trust Anchor"

      render_click(lv, "close_panel")
      assert_patch(lv, ~p"/#{account}/settings/trust_anchors")
    end

    test "closes creation panel on escape", %{conn: conn, account: account, actor: actor} do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/trust_anchors/new")

      render_keydown(lv, "handle_keydown", %{"key" => "Escape"})
      assert_patch(lv, ~p"/#{account}/settings/trust_anchors")
    end

    test "validates required fields", %{conn: conn, account: account, actor: actor} do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/trust_anchors/new")

      html =
        lv
        |> form("#trust-anchor-new-form", trust_anchor: %{name: "", certs: [""]})
        |> render_change()

      assert html =~ "can&#39;t be blank"
    end

    test "refuses to create an eleventh trust anchor", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      for index <- 1..10 do
        Portal.Repo.insert!(%Portal.TrustAnchor{account_id: account.id, name: "Anchor #{index}"})
      end

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/trust_anchors/new")

      html =
        lv
        |> form("#trust-anchor-new-form",
          trust_anchor: %{name: "Eleventh", certs: [sample_cert_pem()]}
        )
        |> render_submit()

      assert html =~ "at most 10 trust anchors"
    end

    test "rejects a bundle that would push the account past the certificate cap", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      # One anchor can hold a whole bundle, so staying under the anchor cap says
      # nothing about how many certificates an attested connect has to check.
      # The certificates have to differ: identical ones are deduplicated.
      bundle =
        Enum.map_join(1..21, fn index ->
          "CA #{index}"
          |> Portal.DeviceTrustFixtures.ca_der()
          |> then(&:public_key.pem_encode([{:Certificate, &1, :not_encrypted}]))
        end)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/trust_anchors/new")

      html =
        lv
        |> form("#trust-anchor-new-form", trust_anchor: %{name: "Bundle", certs: [bundle]})
        |> render_submit()

      assert html =~ "at most 20 CA certificates"
      assert Portal.Repo.aggregate(Portal.TrustAnchorCertificate, :count) == 0
    end

    test "shows validation error for a non-CA certificate", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/trust_anchors/new")

      html =
        lv
        |> form("#trust-anchor-new-form",
          trust_anchor: %{name: "Leaf Cert", certs: [sample_leaf_cert_pem()]}
        )
        |> render_change()

      assert html =~ "all certificates must be CA certificates"
    end

    test "shows validation error for a private key", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/trust_anchors/new")

      html =
        lv
        |> form("#trust-anchor-new-form",
          trust_anchor: %{name: "Private Key", certs: [sample_private_key_pem()]}
        )
        |> render_change()

      assert html =~ "invalid certificate"
    end

    test "creates trust anchor via paste mode", %{conn: conn, account: account, actor: actor} do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/trust_anchors/new")

      html =
        lv
        |> form("#trust-anchor-new-form",
          trust_anchor: %{name: "Pasted CA", certs: [sample_cert_pem()]}
        )
        |> render_submit()

      assert html =~ "Trust anchor created successfully"
      assert_patch(lv, ~p"/#{account}/settings/trust_anchors")
      assert render(lv) =~ "Pasted CA"

      assert trust_anchor = Repo.get_by(TrustAnchor, account_id: account.id, name: "Pasted CA")
      trust_anchor = Repo.preload(trust_anchor, :certificates)
      assert Enum.map(trust_anchor.certificates, &certificate_der/1) == [sample_cert_der()]
    end

    test "re-armors a successfully pasted certificate as PEM instead of raw DER", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/trust_anchors/new")

      html =
        lv
        |> form("#trust-anchor-new-form",
          trust_anchor: %{name: "Pasted CA", certs: [sample_cert_pem()]}
        )
        |> render_change()

      assert [textarea] =
               html
               |> Floki.parse_fragment!()
               |> Floki.find("textarea[name='trust_anchor[certs][]']")

      textarea_value = Floki.text(textarea)
      assert {:ok, [{:Certificate, der, :not_encrypted}]} = X509.pem_decode(textarea_value)
      assert der == sample_cert_der()
    end

    test "rejects a certificate already used by another trust anchor in the account", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      trust_anchor_fixture(account: account, name: "Existing Anchor", certs: [sample_cert_der()])

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/trust_anchors/new")

      html =
        lv
        |> form("#trust-anchor-new-form",
          trust_anchor: %{name: "Duplicate Anchor", certs: [sample_cert_pem()]}
        )
        |> render_submit()

      assert html =~ "already used by another trust anchor"
      refute Repo.get_by(TrustAnchor, account_id: account.id, name: "Duplicate Anchor")
    end

    test "creates trust anchor via upload mode", %{conn: conn, account: account, actor: actor} do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/trust_anchors/new")

      render_change(lv, "validate_new", %{
        "trust_anchor" => %{"name" => "Uploaded CA", "input_mode" => "upload"}
      })

      file =
        file_input(lv, "#trust-anchor-new-form", :cert_file, [
          %{
            name: "ca.pem",
            content: sample_cert_pem(),
            type: "application/x-pem-file"
          }
        ])

      assert render_upload(file, "ca.pem") =~ "ca.pem"

      html =
        render_submit(lv, "create_trust_anchor", %{
          "trust_anchor" => %{"name" => "Uploaded CA", "input_mode" => "upload"}
        })

      assert html =~ "Trust anchor created successfully"
      assert_patch(lv, ~p"/#{account}/settings/trust_anchors")
      assert render(lv) =~ "Uploaded CA"

      assert trust_anchor = Repo.get_by(TrustAnchor, account_id: account.id, name: "Uploaded CA")
      trust_anchor = Repo.preload(trust_anchor, :certificates)
      assert Enum.map(trust_anchor.certificates, &certificate_der/1) == [sample_cert_der()]
    end

    test "creates trust anchor from multiple uploaded files (root + intermediate)", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/trust_anchors/new")

      render_change(lv, "validate_new", %{
        "trust_anchor" => %{"name" => "Multi-file CA", "input_mode" => "upload"}
      })

      issuing_ca_file =
        file_input(lv, "#trust-anchor-new-form", :cert_file, [
          %{name: "issuing_ca.pem", content: sample_cert_pem(), type: "application/x-pem-file"}
        ])

      assert render_upload(issuing_ca_file, "issuing_ca.pem") =~ "issuing_ca.pem"

      additional_ca_file =
        file_input(lv, "#trust-anchor-new-form", :cert_file, [
          %{
            name: "additional_ca.pem",
            content: sample_additional_ca_pem(),
            type: "application/x-pem-file"
          }
        ])

      assert render_upload(additional_ca_file, "additional_ca.pem") =~ "additional_ca.pem"

      html =
        render_submit(lv, "create_trust_anchor", %{
          "trust_anchor" => %{"name" => "Multi-file CA", "input_mode" => "upload"}
        })

      assert html =~ "Trust anchor created successfully"
      assert_patch(lv, ~p"/#{account}/settings/trust_anchors")
      assert render(lv) =~ "Multi-file CA"

      assert trust_anchor =
               Repo.get_by(TrustAnchor, account_id: account.id, name: "Multi-file CA")

      trust_anchor = Repo.preload(trust_anchor, :certificates)
      certs = MapSet.new(trust_anchor.certificates, &certificate_der/1)
      assert certs == MapSet.new([sample_cert_der(), sample_additional_ca_der()])
    end

    test "upload mode submit with no file shows the missing-certificate error", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/trust_anchors/new")

      render_change(lv, "validate_new", %{
        "trust_anchor" => %{"name" => "No File CA", "input_mode" => "upload"}
      })

      html =
        render_submit(lv, "create_trust_anchor", %{
          "trust_anchor" => %{"name" => "No File CA", "input_mode" => "upload"}
        })

      assert html =~ "must contain at least one CA certificate"
      refute Repo.get_by(TrustAnchor, account_id: account.id, name: "No File CA")
    end
  end

  describe ":edit action" do
    test "renders edit panel pre-filled with PEM", %{conn: conn, account: account, actor: actor} do
      trust_anchor =
        trust_anchor_fixture(account: account, name: "Editable CA", certs: [sample_cert_der()])

      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/trust_anchors/#{trust_anchor.id}/edit")

      assert html =~ "Edit Trust Anchor"
      assert html =~ "Editable CA"

      assert [textarea] =
               html
               |> Floki.parse_fragment!()
               |> Floki.find("textarea[name='trust_anchor[certs][]']")

      textarea_value = Floki.text(textarea)
      assert {:ok, [{:Certificate, der, :not_encrypted}]} = X509.pem_decode(textarea_value)
      assert der == sample_cert_der()

      render_click(lv, "close_panel")
      assert_patch(lv, ~p"/#{account}/settings/trust_anchors")
    end

    test "updates trust anchor on submit", %{conn: conn, account: account, actor: actor} do
      trust_anchor = trust_anchor_fixture(account: account, name: "Old Name")

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/trust_anchors/#{trust_anchor.id}/edit")

      html =
        lv
        |> form("#trust-anchor-edit-form",
          trust_anchor: %{name: "New Name", certs: [sample_cert_pem()]}
        )
        |> render_submit()

      assert html =~ "Trust anchor updated successfully"
      assert_patch(lv, ~p"/#{account}/settings/trust_anchors")
      assert render(lv) =~ "New Name"

      assert updated = Repo.get_by(TrustAnchor, account_id: account.id, id: trust_anchor.id)
      assert updated.name == "New Name"
    end
  end

  describe "delete" do
    test "deletes trust anchor through the show panel confirm flow", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      trust_anchor = trust_anchor_fixture(account: account, name: "Deletable CA")

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/trust_anchors/#{trust_anchor.id}")

      render_click(lv, "confirm_delete_trust_anchor")
      assert render(lv) =~ "Delete this trust anchor?"

      render_click(lv, "delete_trust_anchor")

      assert_patch(lv, ~p"/#{account}/settings/trust_anchors")
      refute render(lv) =~ "Deletable CA"
      refute Repo.get_by(TrustAnchor, account_id: account.id, id: trust_anchor.id)
    end

    test "does not crash when the trust anchor was already deleted by another session", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      trust_anchor = trust_anchor_fixture(account: account, name: "Raced CA")

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/trust_anchors/#{trust_anchor.id}")

      Repo.delete!(trust_anchor)

      render_click(lv, "confirm_delete_trust_anchor")
      html = render_click(lv, "delete_trust_anchor")

      assert Process.alive?(lv.pid)
      refute html =~ "Raced CA"
    end
  end
end
