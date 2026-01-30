defmodule PortalWeb.UserpassControllerTest do
  use PortalWeb.ConnCase, async: true

  import ExUnit.CaptureLog
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.AuthProviderFixtures

  @password "TestPassword1234!"

  setup do
    account = account_fixture()
    provider = userpass_provider_fixture(account: account)
    password_hash = Portal.Crypto.hash(:argon2, @password)

    {:ok, account: account, provider: provider, password_hash: password_hash}
  end

  defp create_actor_with_password(attrs, password_hash) do
    actor = actor_fixture(attrs)

    actor
    |> Ecto.Changeset.change(password_hash: password_hash)
    |> Portal.Repo.update!()
  end

  describe "sign_in/2" do
    test "redirects with error when account does not exist", %{conn: conn} do
      conn =
        post(conn, ~p"/nonexistent-account/sign_in/userpass/#{Ecto.UUID.generate()}", %{
          "userpass" => %{"idp_id" => "test@example.com", "secret" => @password}
        })

      assert redirected_to(conn) =~ "nonexistent-account"
    end

    test "redirects with error for invalid password", %{
      conn: conn,
      account: account,
      provider: provider,
      password_hash: password_hash
    } do
      actor =
        create_actor_with_password(
          %{type: :account_admin_user, account: account},
          password_hash
        )

      conn =
        post(conn, ~p"/#{account.id}/sign_in/userpass/#{provider.id}", %{
          "userpass" => %{"idp_id" => actor.email, "secret" => "wrong-password"}
        })

      assert redirected_to(conn) =~ "/sign_in/userpass/#{provider.id}"
      assert flash(conn, :error) =~ "Invalid username or password"
    end

    test "successfully authenticates admin user in portal context", %{
      conn: conn,
      account: account,
      provider: provider,
      password_hash: password_hash
    } do
      actor =
        create_actor_with_password(
          %{type: :account_admin_user, account: account},
          password_hash
        )

      conn =
        post(conn, ~p"/#{account.id}/sign_in/userpass/#{provider.id}", %{
          "userpass" => %{"idp_id" => actor.email, "secret" => @password}
        })

      assert redirected_to(conn) =~ "/sites"
    end

    test "rejects account_user in portal context", %{
      conn: conn,
      account: account,
      provider: provider,
      password_hash: password_hash
    } do
      actor =
        create_actor_with_password(
          %{type: :account_user, account: account},
          password_hash
        )

      conn =
        post(conn, ~p"/#{account.id}/sign_in/userpass/#{provider.id}", %{
          "userpass" => %{"idp_id" => actor.email, "secret" => @password}
        })

      assert redirected_to(conn) =~ "/#{account.id}"
      assert flash(conn, :error) =~ "admin privileges"
    end

    test "successfully authenticates admin user in client context", %{
      conn: conn,
      account: account,
      provider: provider,
      password_hash: password_hash
    } do
      actor =
        create_actor_with_password(
          %{type: :account_admin_user, account: account},
          password_hash
        )

      conn =
        post(conn, ~p"/#{account.id}/sign_in/userpass/#{provider.id}", %{
          "userpass" => %{"idp_id" => actor.email, "secret" => @password},
          "as" => "client",
          "state" => "test-state",
          "nonce" => "test-nonce"
        })

      assert conn.status == 200
      assert conn.resp_body =~ "client_redirect"
    end

    test "successfully authenticates account_user in client context", %{
      conn: conn,
      account: account,
      provider: provider,
      password_hash: password_hash
    } do
      actor =
        create_actor_with_password(
          %{type: :account_user, account: account},
          password_hash
        )

      conn =
        post(conn, ~p"/#{account.id}/sign_in/userpass/#{provider.id}", %{
          "userpass" => %{"idp_id" => actor.email, "secret" => @password},
          "as" => "client",
          "state" => "test-state",
          "nonce" => "test-nonce"
        })

      assert conn.status == 200
      assert conn.resp_body =~ "client_redirect"
    end

    test "successfully authenticates admin user in gui-client context", %{
      conn: conn,
      account: account,
      provider: provider,
      password_hash: password_hash
    } do
      actor =
        create_actor_with_password(
          %{type: :account_admin_user, account: account},
          password_hash
        )

      conn =
        post(conn, ~p"/#{account.id}/sign_in/userpass/#{provider.id}", %{
          "userpass" => %{"idp_id" => actor.email, "secret" => @password},
          "as" => "gui-client",
          "state" => "test-state",
          "nonce" => "test-nonce"
        })

      assert conn.status == 200
      assert conn.resp_body =~ "client_redirect"
    end

    test "successfully authenticates admin user in headless-client context", %{
      conn: conn,
      account: account,
      provider: provider,
      password_hash: password_hash
    } do
      actor =
        create_actor_with_password(
          %{type: :account_admin_user, account: account},
          password_hash
        )

      conn =
        post(conn, ~p"/#{account.id}/sign_in/userpass/#{provider.id}", %{
          "userpass" => %{"idp_id" => actor.email, "secret" => @password},
          "as" => "headless-client",
          "state" => "test-state"
        })

      assert conn.status == 200
      assert conn.resp_body =~ "Copy token to clipboard"
      assert conn.resp_body =~ actor.name
    end

    test "successfully authenticates account_user in headless-client context", %{
      conn: conn,
      account: account,
      provider: provider,
      password_hash: password_hash
    } do
      actor =
        create_actor_with_password(
          %{type: :account_user, account: account},
          password_hash
        )

      conn =
        post(conn, ~p"/#{account.id}/sign_in/userpass/#{provider.id}", %{
          "userpass" => %{"idp_id" => actor.email, "secret" => @password},
          "as" => "headless-client",
          "state" => "test-state"
        })

      assert conn.status == 200
      assert conn.resp_body =~ "Copy token to clipboard"
    end

    test "rejects account_user in gui-client context when using gui-client param", %{
      conn: conn,
      account: account,
      provider: provider,
      password_hash: password_hash
    } do
      actor =
        create_actor_with_password(
          %{type: :account_user, account: account},
          password_hash
        )

      conn =
        post(conn, ~p"/#{account.id}/sign_in/userpass/#{provider.id}", %{
          "userpass" => %{"idp_id" => actor.email, "secret" => @password},
          "as" => "gui-client",
          "state" => "test-state",
          "nonce" => "test-nonce"
        })

      # account_user should be allowed in gui-client context
      assert conn.status == 200
      assert conn.resp_body =~ "client_redirect"
    end

    test "rejects client sign-in when account has exceeded user limits", %{
      conn: conn,
      account: account,
      provider: provider,
      password_hash: password_hash
    } do
      # Set limit exceeded flag on the account
      update_account(account, %{users_limit_exceeded: true})

      actor =
        create_actor_with_password(
          %{type: :account_user, account: account},
          password_hash
        )

      conn =
        post(conn, ~p"/#{account.id}/sign_in/userpass/#{provider.id}", %{
          "userpass" => %{"idp_id" => actor.email, "secret" => @password},
          "as" => "client",
          "state" => "test-state",
          "nonce" => "test-nonce"
        })

      assert redirected_to(conn) =~ "/#{account.id}"
      assert flash(conn, :error) =~ "exceeding billing limits"
    end

    test "logs error and allows gui-client sign-in when account has exceeded monthly active users limits",
         %{
           conn: conn,
           account: account,
           provider: provider,
           password_hash: password_hash
         } do
      # Set limit exceeded flag on the account (seats_limit_exceeded is used for monthly active users)
      update_account(account, %{seats_limit_exceeded: true})

      actor =
        create_actor_with_password(
          %{type: :account_user, account: account},
          password_hash
        )

      log =
        capture_log(fn ->
          conn =
            post(conn, ~p"/#{account.id}/sign_in/userpass/#{provider.id}", %{
              "userpass" => %{"idp_id" => actor.email, "secret" => @password},
              "as" => "gui-client",
              "state" => "test-state",
              "nonce" => "test-nonce"
            })

          # Sign-in should still succeed
          assert conn.status == 200
          assert conn.resp_body =~ "client_redirect"
        end)

      assert log =~ "Account seats limit exceeded"
      assert log =~ "account_id=#{account.id}"
      assert log =~ "account_slug=#{account.slug}"
      assert log =~ "actor_id=#{actor.id}"
    end

    test "rejects headless-client sign-in when account has exceeded limits", %{
      conn: conn,
      account: account,
      provider: provider,
      password_hash: password_hash
    } do
      # Set multiple limit exceeded flags including users
      update_account(account, %{users_limit_exceeded: true, sites_limit_exceeded: true})

      actor =
        create_actor_with_password(
          %{type: :account_user, account: account},
          password_hash
        )

      conn =
        post(conn, ~p"/#{account.id}/sign_in/userpass/#{provider.id}", %{
          "userpass" => %{"idp_id" => actor.email, "secret" => @password},
          "as" => "headless-client",
          "state" => "test-state"
        })

      assert redirected_to(conn) =~ "/#{account.id}"
      assert flash(conn, :error) =~ "exceeding billing limits"
    end

    test "allows client sign-in when account warning does not include user limits", %{
      conn: conn,
      account: account,
      provider: provider,
      password_hash: password_hash
    } do
      # Set a limit flag that doesn't include users or seats
      update_account(account, %{sites_limit_exceeded: true})

      actor =
        create_actor_with_password(
          %{type: :account_user, account: account},
          password_hash
        )

      conn =
        post(conn, ~p"/#{account.id}/sign_in/userpass/#{provider.id}", %{
          "userpass" => %{"idp_id" => actor.email, "secret" => @password},
          "as" => "client",
          "state" => "test-state",
          "nonce" => "test-nonce"
        })

      # Should be allowed - sites warning doesn't block client auth
      assert conn.status == 200
      assert conn.resp_body =~ "client_redirect"
    end

    test "allows portal sign-in when account has exceeded user limits", %{
      conn: conn,
      account: account,
      provider: provider,
      password_hash: password_hash
    } do
      # Set limit exceeded flag on the account
      update_account(account, %{users_limit_exceeded: true})

      actor =
        create_actor_with_password(
          %{type: :account_admin_user, account: account},
          password_hash
        )

      conn =
        post(conn, ~p"/#{account.id}/sign_in/userpass/#{provider.id}", %{
          "userpass" => %{"idp_id" => actor.email, "secret" => @password}
        })

      # Portal sign-in should still be allowed so admins can manage billing
      assert redirected_to(conn) =~ "/sites"
    end
  end
end
