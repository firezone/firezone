defmodule PortalWeb.Settings.TrustAnchors.IndexTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.TrustAnchorFixtures
  import Portal.FeaturesFixtures

  alias Portal.TrustAnchor

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
      assert Enum.map(trust_anchor.certificates, & &1.der) == [sample_cert_der()]
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
      assert Enum.map(trust_anchor.certificates, & &1.der) == [sample_cert_der()]
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
      certs = MapSet.new(trust_anchor.certificates, & &1.der)
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
      assert html =~ "-----BEGIN CERTIFICATE-----"

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
    test "deletes trust anchor through confirm flow", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      trust_anchor = trust_anchor_fixture(account: account, name: "Deletable CA")

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/trust_anchors")

      lv
      |> element("button[phx-click='toggle_trust_anchor_actions'][phx-value-id='#{trust_anchor.id}']")
      |> render_click()

      lv
      |> element("button[phx-click='request_delete'][phx-value-id='#{trust_anchor.id}']")
      |> render_click()

      html = render(lv)
      assert html =~ "Delete this trust anchor?"

      lv
      |> element("button[phx-click='delete'][phx-value-id='#{trust_anchor.id}']")
      |> render_click()

      refute render(lv) =~ "Deletable CA"
      refute Repo.get_by(TrustAnchor, account_id: account.id, id: trust_anchor.id)
    end

    test "does not crash when deleting an id that no longer exists", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/trust_anchors")

      html = render_click(lv, "delete", %{"id" => Ecto.UUID.generate()})

      assert Process.alive?(lv.pid)
      assert html =~ "Trust Anchors"
    end
  end
end
