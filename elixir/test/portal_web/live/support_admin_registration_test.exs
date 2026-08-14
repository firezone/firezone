defmodule PortalWeb.SupportAdminRegistrationTest do
  use PortalWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Portal.SupportAdminFixtures
  import Portal.WebAuthnFixtures

  alias Portal.SupportAdmin

  defp registration_payload(html, authenticator) do
    [challenge_b64] = Regex.run(~r/data-challenge="([^"]+)"/, html, capture: :all_but_first)
    challenge = challenge_stub(Base.url_decode64!(challenge_b64, padding: false))
    response = registration_response(authenticator, challenge)

    %{
      "attestation_object" => Base.url_encode64(response.attestation_object, padding: false),
      "client_data_json" => Base.url_encode64(response.client_data_json, padding: false),
      "raw_id" => Base.url_encode64(authenticator.credential_id, padding: false)
    }
  end

  describe "mount" do
    test "404s for an unknown token", %{conn: conn} do
      assert_error_sent 404, fn ->
        live(conn, ~p"/support_admin/register/#{Portal.Crypto.random_token(32)}")
      end
    end

    test "404s for an expired token", %{conn: conn} do
      {_support_admin, token} =
        provisioned_support_admin_fixture(
          registration_token_expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
        )

      assert_error_sent 404, fn ->
        live(conn, ~p"/support_admin/register/#{token}")
      end
    end

    test "renders the registration page for a valid token", %{conn: conn} do
      {support_admin, token} = provisioned_support_admin_fixture()

      {:ok, _lv, html} = live(conn, ~p"/support_admin/register/#{token}")

      assert html =~ support_admin.email
      assert html =~ "Create passkey"
      assert html =~ "data-challenge="
    end

    test "offers replacement when a passkey is already registered", %{conn: conn} do
      {support_admin, _authenticator} = registered_support_admin_fixture()
      token = Portal.Crypto.random_token(32)

      support_admin
      |> Ecto.Changeset.change(
        registration_token_hash: Portal.Crypto.hash(:sha256, token),
        registration_token_expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
      )
      |> Portal.Repo.update!()

      {:ok, _lv, html} = live(conn, ~p"/support_admin/register/#{token}")

      assert html =~ "Replace passkey"
      assert html =~ "replaces it"
    end
  end

  describe "verify_registration" do
    test "registers the passkey and consumes the token", %{conn: conn} do
      {support_admin, token} = provisioned_support_admin_fixture()
      authenticator = generate_authenticator()

      {:ok, lv, _html} = live(conn, ~p"/support_admin/register/#{token}")

      html = render_hook(lv, "verify_registration", registration_payload(render(lv), authenticator))

      assert html =~ "You can close this tab"

      reloaded = Portal.Repo.get!(SupportAdmin, support_admin.id)
      assert reloaded.passkey_credential_id == authenticator.credential_id
      assert Portal.Crypto.WebAuthn.decode_cose_key(reloaded.passkey_public_key) == authenticator.cose_key
      assert reloaded.passkey_registered_at
      assert is_nil(reloaded.registration_token_hash)
      assert is_nil(reloaded.registration_token_expires_at)

      assert_error_sent 404, fn ->
        live(conn, ~p"/support_admin/register/#{token}")
      end
    end

    test "replaces an existing passkey", %{conn: conn} do
      {support_admin, old_authenticator} = registered_support_admin_fixture()
      token = Portal.Crypto.random_token(32)

      support_admin
      |> Ecto.Changeset.change(
        registration_token_hash: Portal.Crypto.hash(:sha256, token),
        registration_token_expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
      )
      |> Portal.Repo.update!()

      new_authenticator = generate_authenticator()

      {:ok, lv, _html} = live(conn, ~p"/support_admin/register/#{token}")
      render_hook(lv, "verify_registration", registration_payload(render(lv), new_authenticator))

      reloaded = Portal.Repo.get!(SupportAdmin, support_admin.id)
      assert reloaded.passkey_credential_id == new_authenticator.credential_id
      refute reloaded.passkey_credential_id == old_authenticator.credential_id
    end

    test "rejects a tampered attestation and offers retry", %{conn: conn} do
      {support_admin, token} = provisioned_support_admin_fixture()
      authenticator = generate_authenticator()

      {:ok, lv, _html} = live(conn, ~p"/support_admin/register/#{token}")

      payload =
        render(lv)
        |> registration_payload(authenticator)
        |> Map.put(
          "client_data_json",
          Base.url_encode64(
            JSON.encode!(%{
              "type" => "webauthn.create",
              "challenge" => Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
              "origin" => Portal.Crypto.WebAuthn.origin()
            }),
            padding: false
          )
        )

      html = render_hook(lv, "verify_registration", payload)

      assert html =~ "Passkey registration failed"

      reloaded = Portal.Repo.get!(SupportAdmin, support_admin.id)
      assert is_nil(reloaded.passkey_credential_id)
      assert reloaded.registration_token_hash
    end

    test "renders client-side error messages", %{conn: conn} do
      {_support_admin, token} = provisioned_support_admin_fixture()

      {:ok, lv, _html} = live(conn, ~p"/support_admin/register/#{token}")

      html = render_hook(lv, "registration_failed", %{"error" => "NotAllowedError"})
      assert html =~ "cancelled or timed out"

      html = render_hook(lv, "registration_failed", %{"error" => "unsupported"})
      assert html =~ "doesn&#39;t support passkeys"
    end
  end
end
