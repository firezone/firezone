defmodule PortalWeb.SupportRequestControllerTest do
  use PortalWeb.ConnCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.AuthProviderFixtures

  alias Portal.Actor
  alias Portal.FirezoneSupport
  alias Portal.Workers.DeleteExpiredSupportAccess

  setup %{conn: conn} do
    Portal.Config.put_env_override(:outbound_email_adapter_configured?, true)
    account = account_fixture()
    actor = actor_fixture(account: account, type: :account_admin_user)
    conn = authorize_conn(conn, actor)

    {:ok, account: account, actor: actor, conn: conn}
  end

  describe "create/2" do
    test "sends the problem report without granting access", %{conn: conn, account: account} do
      conn =
        post(conn, ~p"/#{account.slug}/support_request", %{
          "support_request" => %{"problem" => "DNS is broken"},
          "redirect_to" => "/#{account.slug}/sites"
        })

      assert redirected_to(conn) == "/#{account.slug}/sites"
      refute flash(conn, :success)

      assert_received {:email, email}
      assert email.subject =~ "SUPPORT REQUEST"
      assert "support@firezone.dev" in Enum.map(email.to, &elem(&1, 1))
      assert email.text_body =~ "DNS is broken"
      assert email.text_body =~ "Access granted: no"

      refute Portal.Repo.get_by(FirezoneSupport.AuthProvider, account_id: account.id)
      refute_enqueued(worker: DeleteExpiredSupportAccess)
    end

    test "grants access, creates the provider, and schedules cleanup", %{
      conn: conn,
      account: account
    } do
      conn =
        post(conn, ~p"/#{account.slug}/support_request", %{
          "support_request" => %{"problem" => "Need help", "grant_access" => "true"},
          "redirect_to" => "/#{account.slug}/sites"
        })

      assert redirected_to(conn) == "/#{account.slug}/sites"
      refute flash(conn, :success)

      provider = Portal.Repo.get_by!(FirezoneSupport.AuthProvider, account_id: account.id)
      parent = Portal.Repo.get_by!(Portal.AuthProvider, id: provider.id)
      assert parent.type == :firezone_support

      in_24h = DateTime.add(DateTime.utc_now(), 86_400, :second)
      assert DateTime.diff(in_24h, provider.expires_at, :second) < 60

      assert_enqueued(
        worker: DeleteExpiredSupportAccess,
        args: %{"account_id" => account.id, "auth_provider_id" => provider.id}
      )

      assert_received {:email, email}
      assert email.text_body =~ "Access granted: YES"
    end

    test "rejects a second grant while one is active", %{conn: conn, account: account} do
      firezone_support_provider_fixture(account: account)

      conn =
        post(conn, ~p"/#{account.slug}/support_request", %{
          "support_request" => %{"problem" => "More help", "grant_access" => "true"}
        })

      assert flash(conn, :error) =~ "already active"
      refute_received {:email, _email}
    end

    test "rejects an empty problem description", %{conn: conn, account: account} do
      conn =
        post(conn, ~p"/#{account.slug}/support_request", %{
          "support_request" => %{"problem" => "   "}
        })

      assert flash(conn, :error) =~ "describe the problem"
      refute_received {:email, _email}
    end

    test "sanitizes foreign redirect_to paths", %{conn: conn, account: account} do
      conn =
        post(conn, ~p"/#{account.slug}/support_request", %{
          "support_request" => %{"problem" => "Help"},
          "redirect_to" => "/some-other-account/sites"
        })

      assert redirected_to(conn) =~ "/#{account.slug}/"
    end

    test "requires authentication", %{account: account} do
      conn =
        post(build_conn(), ~p"/#{account.slug}/support_request", %{
          "support_request" => %{"problem" => "Help"}
        })

      assert redirected_to(conn) =~ "/sign_in"
    end
  end

  describe "end_support/2" do
    test "deletes the provider, support actors, and their sessions", %{
      conn: conn,
      account: account
    } do
      provider = firezone_support_provider_fixture(account: account)
      support_actor = support_actor_fixture(account: account)

      context = %Portal.Authentication.Context{
        type: :portal,
        user_agent: "Test 1.0",
        remote_ip: {127, 0, 0, 1}
      }

      {:ok, session} =
        Portal.Authentication.create_portal_session(
          support_actor,
          provider.id,
          context,
          DateTime.add(DateTime.utc_now(), 3_600, :second)
        )

      conn = post(conn, ~p"/#{account.slug}/support_request/end", %{})

      assert flash(conn, :success) =~ "Support session ended"
      refute Portal.Repo.get_by(Portal.AuthProvider, id: provider.id)
      refute Portal.Repo.get_by(FirezoneSupport.AuthProvider, id: provider.id)
      refute Portal.Repo.get_by(Actor, account_id: account.id, id: support_actor.id)
      refute Portal.Repo.get_by(Portal.PortalSession, id: session.id)
    end

    test "does not delete regular actors", %{conn: conn, account: account, actor: actor} do
      firezone_support_provider_fixture(account: account)

      post(conn, ~p"/#{account.slug}/support_request/end", %{})

      assert Portal.Repo.get_by(Actor, account_id: account.id, id: actor.id)
    end

    test "no-ops gracefully when support is not active", %{conn: conn, account: account} do
      conn = post(conn, ~p"/#{account.slug}/support_request/end", %{})

      assert flash(conn, :info) =~ "not active"
    end

    test "signs the support actor out when they end their own session", %{account: account} do
      provider = firezone_support_provider_fixture(account: account)
      support_actor = support_actor_fixture(account: account)

      conn =
        build_conn()
        |> Map.put(:secret_key_base, PortalWeb.Endpoint.config(:secret_key_base))
        |> put_req_header("user-agent", "FooBar 1.1")
        |> authorize_conn_with_provider(support_actor, provider)
        |> post(~p"/#{account.slug}/support_request/end", %{})

      assert redirected_to(conn) == ~p"/#{account.slug}/sign_in"
      assert flash(conn, :info) =~ "signed out"
      refute Portal.Repo.get_by(Portal.AuthProvider, id: provider.id)
      refute Portal.Repo.get_by(Actor, account_id: account.id, id: support_actor.id)
    end
  end
end
