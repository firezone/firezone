defmodule PortalWeb.SupportControllerTest do
  use PortalWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.AuthProviderFixtures
  import Portal.SupportAdminFixtures
  import Portal.WebAuthnFixtures

  alias Portal.Actor
  alias Portal.SupportAdmin

  setup do
    Portal.Config.put_env_override(:outbound_email_adapter_configured?, true)
    account = account_fixture()
    provider = firezone_support_provider_fixture(account: account)
    {support_admin, authenticator} = registered_support_admin_fixture()

    {:ok,
     account: account,
     provider: provider,
     support_admin: support_admin,
     authenticator: authenticator}
  end

  defp recycle_with_cookie(conn) do
    conn =
      if conn.state == :sent do
        conn
      else
        Plug.Conn.send_resp(conn, 200, "")
      end

    conn
    |> then(&Plug.Test.recycle_cookies(build_conn(), &1))
    |> Map.put(:secret_key_base, PortalWeb.Endpoint.config(:secret_key_base))
  end

  defp fetch_support_cookie(conn) do
    conn
    |> recycle_with_cookie()
    |> PortalWeb.Cookie.Support.fetch()
  end

  defp extract_code_from_email(email) do
    case Regex.run(~r/\n([a-z0-9]{6})\n/, email.text_body) do
      [_, code] -> code
      _ -> raise "Could not extract code from email: #{email.text_body}"
    end
  end

  defp start_sign_in(conn, account, support_admin, params \\ %{}) do
    conn =
      post(
        conn,
        ~p"/#{account.id}/support?#{params}",
        %{"email" => %{"email" => support_admin.email}}
      )

    assert_received {:email, email}
    {conn, extract_code_from_email(email)}
  end

  defp verify_otp(conn, account, code, params \\ %{}) do
    conn
    |> recycle_with_cookie()
    |> post(~p"/#{account.id}/support/verify?#{params}", %{"secret" => code})
  end

  defp complete_sign_in(conn, account, authenticator, params \\ %{}, opts \\ []) do
    cookie = fetch_support_cookie(conn)
    assertion = assertion_response(authenticator, cookie.challenge, opts)

    conn
    |> recycle_with_cookie()
    |> post(~p"/#{account.id}/support/complete?#{params}", encode_assertion_params(assertion))
  end

  describe "sign_in/2" do
    test "404s when the account has no support provider", %{conn: conn, support_admin: sa} do
      other_account = account_fixture()

      assert_error_sent 404, fn ->
        post(conn, ~p"/#{other_account.id}/support", %{"email" => %{"email" => sa.email}})
      end
    end

    test "404s when the provider is expired", %{conn: conn, support_admin: sa} do
      other_account = account_fixture()

      firezone_support_provider_fixture(
        account: other_account,
        expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
      )

      assert_error_sent 404, fn ->
        post(conn, ~p"/#{other_account.id}/support", %{"email" => %{"email" => sa.email}})
      end
    end

    test "sends an OTP email for a registered support admin", %{
      conn: conn,
      account: account,
      support_admin: support_admin
    } do
      conn =
        post(conn, ~p"/#{account.id}/support", %{"email" => %{"email" => support_admin.email}})

      assert redirected_to(conn) == ~p"/#{account.id}/support/verify?"
      assert_received {:email, email}
      assert email.subject == "Firezone Support sign-in code"
      assert support_admin.email in Enum.map(email.to, &elem(&1, 1))
    end

    test "responds identically for unknown emails without sending an email", %{
      conn: conn,
      account: account,
      support_admin: support_admin
    } do
      known_conn =
        post(conn, ~p"/#{account.id}/support", %{"email" => %{"email" => support_admin.email}})

      assert_received {:email, _email}

      unknown_conn =
        post(build_conn(), ~p"/#{account.id}/support", %{
          "email" => %{"email" => "nobody@firezone.dev"}
        })

      refute_received {:email, _email}

      assert redirected_to(known_conn) == redirected_to(unknown_conn)
      assert flash(known_conn, :error) == flash(unknown_conn, :error)

      known_cookie = fetch_support_cookie(known_conn)
      unknown_cookie = fetch_support_cookie(unknown_conn)
      assert known_cookie.stage == :otp
      assert unknown_cookie.stage == :otp
      assert known_cookie.account_id == unknown_cookie.account_id
    end

    test "does not send an email for an admin without a registered passkey", %{
      conn: conn,
      account: account
    } do
      unregistered = support_admin_fixture()

      conn =
        post(conn, ~p"/#{account.id}/support", %{"email" => %{"email" => unregistered.email}})

      refute_received {:email, _email}
      assert redirected_to(conn) == ~p"/#{account.id}/support/verify?"
    end

    test "rate-limited requests do not rotate the stored OTP", %{
      account: account,
      support_admin: support_admin
    } do
      for _send <- 1..3 do
        post(build_conn(), ~p"/#{account.id}/support", %{
          "email" => %{"email" => support_admin.email}
        })

        assert_received {:email, _email}
      end

      hash_before = Portal.Repo.get!(SupportAdmin, support_admin.id).otp_code_hash

      limited_conn =
        post(build_conn(), ~p"/#{account.id}/support", %{
          "email" => %{"email" => support_admin.email}
        })

      refute_received {:email, _email}
      assert Portal.Repo.get!(SupportAdmin, support_admin.id).otp_code_hash == hash_before

      unknown_conn =
        post(build_conn(), ~p"/#{account.id}/support", %{
          "email" => %{"email" => "nobody@firezone.dev"}
        })

      assert redirected_to(limited_conn) == redirected_to(unknown_conn)
      assert flash(limited_conn, :error) == flash(unknown_conn, :error)
    end

    test "carries sign-in params through the redirect", %{
      conn: conn,
      account: account,
      support_admin: support_admin
    } do
      params = %{"as" => "client", "state" => "STATE", "nonce" => "NONCE"}
      {conn, _code} = start_sign_in(conn, account, support_admin, params)

      assert redirected_to(conn) ==
               ~p"/#{account.id}/support/verify?as=client&nonce=NONCE&state=STATE"
    end
  end

  describe "verify_otp/2" do
    test "advances to the passkey stage on a valid code", %{
      conn: conn,
      account: account,
      support_admin: support_admin
    } do
      {conn, code} = start_sign_in(conn, account, support_admin)
      conn = verify_otp(conn, account, code)

      assert redirected_to(conn) == ~p"/#{account.id}/support/passkey?"

      cookie = fetch_support_cookie(conn)
      assert cookie.stage == :passkey
      assert %Portal.Crypto.WebAuthn.Challenge{} = cookie.challenge
      assert [{_credential_id, _cose_key}] = cookie.challenge.allow_credentials
    end

    test "rejects an invalid code and counts attempts", %{
      conn: conn,
      account: account,
      support_admin: support_admin
    } do
      {conn, _code} = start_sign_in(conn, account, support_admin)
      conn = verify_otp(conn, account, "wrong1")

      assert redirected_to(conn) == ~p"/#{account.id}/support/verify?"
      assert flash(conn, :error) =~ "invalid or expired"
      assert Portal.Repo.get!(SupportAdmin, support_admin.id).otp_attempts == 1
    end

    test "rejects the correct code after three failed attempts", %{
      conn: conn,
      account: account,
      support_admin: support_admin
    } do
      {conn, code} = start_sign_in(conn, account, support_admin)

      conn =
        Enum.reduce(1..3, conn, fn _attempt, conn ->
          verify_otp(conn, account, "wrong1")
        end)

      conn = verify_otp(conn, account, code)
      assert flash(conn, :error) =~ "invalid or expired"
    end

    test "redirects to the start when the cookie is missing", %{conn: conn, account: account} do
      conn = post(conn, ~p"/#{account.id}/support/verify", %{"secret" => "abc123"})

      assert redirected_to(conn) == ~p"/#{account.id}/support?"
      assert flash(conn, :error) =~ "missing or expired"
    end

    test "404s when the provider is revoked mid-flow", %{
      conn: conn,
      account: account,
      provider: provider,
      support_admin: support_admin
    } do
      {conn, code} = start_sign_in(conn, account, support_admin)

      Portal.Repo.get_by!(Portal.AuthProvider, id: provider.id) |> Portal.Repo.delete!()

      assert_error_sent 404, fn ->
        verify_otp(conn, account, code)
      end
    end
  end

  describe "complete/2" do
    test "signs in to the portal and creates the support actor", %{
      conn: conn,
      account: account,
      support_admin: support_admin,
      authenticator: authenticator
    } do
      {conn, code} = start_sign_in(conn, account, support_admin)
      conn = verify_otp(conn, account, code)
      conn = complete_sign_in(conn, account, authenticator)

      assert redirected_to(conn) =~ "/#{account.slug}/"
      assert conn.resp_cookies["sess_#{account.id}"]

      tagged_email = Actor.support_email(support_admin.email)
      actor = Portal.Repo.get_by!(Actor, account_id: account.id, email: tagged_email)
      assert actor.type == :firezone_support
      assert actor.name == "Firezone Support"
      assert Actor.support?(actor)

      session = Portal.Repo.get_by!(Portal.PortalSession, actor_id: actor.id)
      assert session.auth_provider_id
    end

    test "caps the portal session at the provider expiry", %{
      conn: conn,
      support_admin: support_admin,
      authenticator: authenticator
    } do
      account = account_fixture()
      expires_at = DateTime.add(DateTime.utc_now(), 600, :second)
      firezone_support_provider_fixture(account: account, expires_at: expires_at)

      {conn, code} = start_sign_in(conn, account, support_admin)
      conn = verify_otp(conn, account, code)
      complete_sign_in(conn, account, authenticator)

      tagged_email = Actor.support_email(support_admin.email)
      actor = Portal.Repo.get_by!(Actor, account_id: account.id, email: tagged_email)
      session = Portal.Repo.get_by!(Portal.PortalSession, actor_id: actor.id)
      assert DateTime.compare(session.expires_at, expires_at) == :eq
    end

    test "reuses the support actor across sign-ins", %{
      conn: conn,
      account: account,
      support_admin: support_admin,
      authenticator: authenticator
    } do
      {conn1, code} = start_sign_in(conn, account, support_admin)
      conn1 = verify_otp(conn1, account, code)
      complete_sign_in(conn1, account, authenticator)

      {conn2, code} = start_sign_in(build_conn(), account, support_admin)
      conn2 = verify_otp(conn2, account, code)
      complete_sign_in(conn2, account, authenticator)

      tagged_email = Actor.support_email(support_admin.email)

      assert [_actor] =
               Portal.Repo.all(
                 from(a in Actor,
                   where: a.account_id == ^account.id and a.email == ^tagged_email
                 )
               )
    end

    test "coexists with a real actor using the untagged staff email", %{
      conn: conn,
      account: account,
      support_admin: support_admin,
      authenticator: authenticator
    } do
      real_actor =
        actor_fixture(account: account, type: :account_admin_user, email: support_admin.email)

      {conn, code} = start_sign_in(conn, account, support_admin)
      conn = verify_otp(conn, account, code)
      conn = complete_sign_in(conn, account, authenticator)

      assert redirected_to(conn) =~ "/#{account.slug}/"

      tagged_email = Actor.support_email(support_admin.email)
      support_actor = Portal.Repo.get_by!(Actor, account_id: account.id, email: tagged_email)
      refute support_actor.id == real_actor.id
      assert Portal.Repo.get_by(Actor, account_id: account.id, id: real_actor.id)
    end

    test "hands off to the GUI client with a capped token", %{
      conn: conn,
      support_admin: support_admin,
      authenticator: authenticator
    } do
      account = account_fixture()
      expires_at = DateTime.add(DateTime.utc_now(), 600, :second)
      firezone_support_provider_fixture(account: account, expires_at: expires_at)

      params = %{"as" => "client", "state" => "STATE", "nonce" => "NONCE"}
      {conn, code} = start_sign_in(conn, account, support_admin, params)
      conn = verify_otp(conn, account, code, params)
      conn = complete_sign_in(conn, account, authenticator, params)

      assert html_response(conn, 200) =~ "client_redirect"
      assert conn.resp_cookies["client_auth"]

      tagged_email = Actor.support_email(support_admin.email)
      actor = Portal.Repo.get_by!(Actor, account_id: account.id, email: tagged_email)
      token = Portal.Repo.get_by!(Portal.ClientToken, actor_id: actor.id)
      assert token.auth_provider_id
      assert DateTime.compare(token.expires_at, expires_at) == :eq
    end

    test "signs in from clients even when billing limits are exceeded", %{
      conn: conn,
      support_admin: support_admin,
      authenticator: authenticator
    } do
      account = account_fixture()
      firezone_support_provider_fixture(account: account)

      Portal.Repo.get!(Portal.Account, account.id)
      |> Ecto.Changeset.change(users_limit_exceeded: true)
      |> Portal.Repo.update!()

      params = %{"as" => "client", "state" => "STATE", "nonce" => "NONCE"}
      {conn, code} = start_sign_in(conn, account, support_admin, params)
      conn = verify_otp(conn, account, code, params)
      conn = complete_sign_in(conn, account, authenticator, params)

      assert html_response(conn, 200) =~ "client_redirect"
    end

    test "rejects a sign count regression", %{
      conn: conn,
      account: account,
      support_admin: support_admin,
      authenticator: authenticator
    } do
      support_admin
      |> Ecto.Changeset.change(passkey_sign_count: 100)
      |> Portal.Repo.update!()

      {conn, code} = start_sign_in(conn, account, support_admin)
      conn = verify_otp(conn, account, code)
      conn = complete_sign_in(conn, account, authenticator, %{}, sign_count: 5)

      assert redirected_to(conn) == ~p"/#{account.id}/support/passkey?"
      assert flash(conn, :error) =~ "Passkey verification failed"

      tagged_email = Actor.support_email(support_admin.email)
      refute Portal.Repo.get_by(Actor, account_id: account.id, email: tagged_email)
    end

    test "updates the stored sign count on success", %{
      conn: conn,
      account: account,
      support_admin: support_admin,
      authenticator: authenticator
    } do
      {conn, code} = start_sign_in(conn, account, support_admin)
      conn = verify_otp(conn, account, code)
      complete_sign_in(conn, account, authenticator, %{}, sign_count: 42)

      assert Portal.Repo.get!(SupportAdmin, support_admin.id).passkey_sign_count == 42
    end

    test "rejects a cookie minted for a different account", %{
      conn: conn,
      account: account,
      support_admin: support_admin,
      authenticator: authenticator
    } do
      other_account = account_fixture()
      firezone_support_provider_fixture(account: other_account)

      {conn, code} = start_sign_in(conn, account, support_admin)
      conn = verify_otp(conn, account, code)
      conn = complete_sign_in(conn, other_account, authenticator)

      assert redirected_to(conn) == ~p"/#{other_account.id}/support?"
      assert flash(conn, :error) =~ "missing or expired"
    end

    test "404s when the provider expires between passkey page and POST", %{
      conn: conn,
      account: account,
      provider: provider,
      support_admin: support_admin,
      authenticator: authenticator
    } do
      {conn, code} = start_sign_in(conn, account, support_admin)
      conn = verify_otp(conn, account, code)

      Portal.Repo.get_by!(Portal.FirezoneSupport.AuthProvider, id: provider.id)
      |> Ecto.Changeset.change(expires_at: DateTime.add(DateTime.utc_now(), -1, :second))
      |> Portal.Repo.update!()

      assert_error_sent 404, fn ->
        complete_sign_in(conn, account, authenticator)
      end
    end

    test "rejects replaying the exact same assertion and cookie", %{
      conn: conn,
      account: account,
      support_admin: support_admin,
      authenticator: authenticator
    } do
      {conn, code} = start_sign_in(conn, account, support_admin)
      conn = verify_otp(conn, account, code)

      cookie = fetch_support_cookie(conn)
      assertion = assertion_response(authenticator, cookie.challenge, sign_count: 0)
      params = encode_assertion_params(assertion)

      first =
        conn
        |> recycle_with_cookie()
        |> post(~p"/#{account.id}/support/complete", params)

      assert redirected_to(first) =~ "/#{account.slug}/"

      replay =
        conn
        |> recycle_with_cookie()
        |> post(~p"/#{account.id}/support/complete", params)

      assert redirected_to(replay) == ~p"/#{account.id}/support?"
      assert flash(replay, :error) =~ "missing or expired"

      tagged_email = Actor.support_email(support_admin.email)
      actor = Portal.Repo.get_by!(Actor, account_id: account.id, email: tagged_email)
      assert [_session] = Portal.Repo.all(from(s in Portal.PortalSession, where: s.actor_id == ^actor.id))
    end

    test "rejects a tampered assertion", %{
      conn: conn,
      account: account,
      support_admin: support_admin,
      authenticator: authenticator
    } do
      {conn, code} = start_sign_in(conn, account, support_admin)
      conn = verify_otp(conn, account, code)

      cookie = fetch_support_cookie(conn)
      other_authenticator = Map.put(generate_authenticator(), :credential_id, authenticator.credential_id)
      assertion = assertion_response(other_authenticator, cookie.challenge)

      conn =
        conn
        |> recycle_with_cookie()
        |> post(~p"/#{account.id}/support/complete", encode_assertion_params(assertion))

      assert redirected_to(conn) == ~p"/#{account.id}/support/passkey?"
      assert flash(conn, :error) =~ "Passkey verification failed"
    end
  end
end
