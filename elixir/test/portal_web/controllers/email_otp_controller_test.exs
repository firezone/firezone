defmodule PortalWeb.EmailOTPControllerTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.AuthProviderFixtures

  setup do
    Portal.Config.put_env_override(:outbound_email_adapter_configured?, true)
    account = account_fixture()
    provider = email_otp_provider_fixture(account: account)

    {:ok, account: account, provider: provider}
  end

  defp get_cookie_state(conn) do
    conn
    |> then(&Plug.Test.recycle_cookies(build_conn(), &1))
    |> Map.put(:secret_key_base, PortalWeb.Endpoint.config(:secret_key_base))
    |> PortalWeb.Cookie.EmailOTP.fetch_state()
  end

  describe "sign_in/2" do
    test "redirects with error when account does not exist", %{conn: conn} do
      conn =
        post(conn, ~p"/nonexistent-account/sign_in/email_otp/#{Ecto.UUID.generate()}", %{
          "email" => %{"email" => "test@example.com"}
        })

      assert redirected_to(conn) == ~p"/nonexistent-account"
      assert flash(conn, :error) =~ "You may not use this method to sign in"
    end

    test "redirects with error when provider does not exist", %{
      conn: conn,
      account: account
    } do
      conn =
        post(conn, ~p"/#{account.id}/sign_in/email_otp/#{Ecto.UUID.generate()}", %{
          "email" => %{"email" => "test@example.com"}
        })

      assert redirected_to(conn) == ~p"/#{account.id}"
      assert flash(conn, :error) =~ "You may not use this method to sign in"
    end

    test "redirects with error when provider is disabled", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      provider
      |> Ecto.Changeset.change(is_disabled: true)
      |> Portal.Repo.update!()

      conn =
        post(conn, ~p"/#{account.id}/sign_in/email_otp/#{provider.id}", %{
          "email" => %{"email" => "test@example.com"}
        })

      assert redirected_to(conn) == ~p"/#{account.id}"
      assert flash(conn, :error) =~ "You may not use this method to sign in"
    end

    test "sets cookie with dummy passcode_id when email does not exist", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      nonexistent_email = "nonexistent@example.com"

      conn =
        post(conn, ~p"/#{account.id}/sign_in/email_otp/#{provider.id}", %{
          "email" => %{"email" => nonexistent_email}
        })

      # Should still redirect to verify page (no oracle)
      assert redirected_to(conn) =~
               ~p"/#{account.id}/sign_in/email_otp/#{provider.id}"

      # Cookie should be set with email and dummy passcode_id (no oracle)
      state = get_cookie_state(conn)
      assert state["email"] == nonexistent_email
      assert state["one_time_passcode_id"] != nil
    end

    test "sets cookie with real passcode_id when email exists", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      actor =
        actor_fixture(
          type: :account_admin_user,
          account: account,
          allow_email_otp_sign_in: true
        )

      conn =
        post(conn, ~p"/#{account.id}/sign_in/email_otp/#{provider.id}", %{
          "email" => %{"email" => actor.email}
        })

      # Should redirect to verify page
      assert redirected_to(conn) =~
               ~p"/#{account.id}/sign_in/email_otp/#{provider.id}"

      # Verify the cookie contains the email and a real passcode_id
      state = get_cookie_state(conn)
      assert state["email"] == actor.email
      assert state["one_time_passcode_id"] != nil

      # Email should have been sent
      assert_received {:email, email}
      assert email.to == [{"", actor.email}]
    end

    test "sends email for account_user with allow_email_otp_sign_in", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      actor =
        actor_fixture(
          type: :account_user,
          account: account,
          allow_email_otp_sign_in: true
        )

      conn =
        post(conn, ~p"/#{account.id}/sign_in/email_otp/#{provider.id}", %{
          "email" => %{"email" => actor.email}
        })

      assert redirected_to(conn) =~
               ~p"/#{account.id}/sign_in/email_otp/#{provider.id}"

      # Cookie should be set with real passcode_id
      state = get_cookie_state(conn)
      assert state["email"] == actor.email
      assert state["one_time_passcode_id"] != nil

      # Email should have been sent
      assert_received {:email, email}
      assert email.to == [{"", actor.email}]
    end

    # Note: This scenario shouldn't be possible in practice because a DB constraint
    # prevents api_client actors from having emails, but we test for defense in depth.
    test "does not send email for api_client actor type", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      actor = actor_fixture(type: :api_client, account: account)
      email = "api_client_#{actor.id}@example.com"

      conn =
        post(conn, ~p"/#{account.id}/sign_in/email_otp/#{provider.id}", %{
          "email" => %{"email" => email}
        })

      # Should still redirect to verify page (no oracle)
      assert redirected_to(conn) =~
               ~p"/#{account.id}/sign_in/email_otp/#{provider.id}"

      # Cookie should still be set with dummy passcode_id (no oracle)
      state = get_cookie_state(conn)
      assert state["email"] == email
      assert state["one_time_passcode_id"] != nil

      # No email should have been sent
      refute_received {:email, _}
    end

    # Note: This scenario shouldn't be possible in practice because a DB constraint
    # prevents service_account actors from having emails, but we test for defense in depth.
    test "does not send email for service_account actor type", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      actor = actor_fixture(type: :service_account, account: account)
      email = "service_account_#{actor.id}@example.com"

      conn =
        post(conn, ~p"/#{account.id}/sign_in/email_otp/#{provider.id}", %{
          "email" => %{"email" => email}
        })

      # Should still redirect to verify page (no oracle)
      assert redirected_to(conn) =~
               ~p"/#{account.id}/sign_in/email_otp/#{provider.id}"

      # Cookie should still be set with dummy passcode_id (no oracle)
      state = get_cookie_state(conn)
      assert state["email"] == email
      assert state["one_time_passcode_id"] != nil

      # No email should have been sent
      refute_received {:email, _}
    end

    test "does not send email for actor without allow_email_otp_sign_in", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      actor =
        actor_fixture(
          type: :account_admin_user,
          account: account,
          allow_email_otp_sign_in: false
        )

      conn =
        post(conn, ~p"/#{account.id}/sign_in/email_otp/#{provider.id}", %{
          "email" => %{"email" => actor.email}
        })

      # Should still redirect to verify page (no oracle)
      assert redirected_to(conn) =~
               ~p"/#{account.id}/sign_in/email_otp/#{provider.id}"

      # Cookie should still be set with dummy passcode_id (no oracle)
      state = get_cookie_state(conn)
      assert state["email"] == actor.email
      assert state["one_time_passcode_id"] != nil

      # No email should have been sent
      refute_received {:email, _}
    end
  end

  describe "verify/2 POST" do
    test "redirects with error when cookie is missing", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      conn =
        post(conn, ~p"/#{account.id}/sign_in/email_otp/#{provider.id}/verify", %{
          "secret" => "123456"
        })

      assert redirected_to(conn) == ~p"/#{account.id}"
      assert flash(conn, :error) =~ "missing or expired"
    end

    test "redirects with error when code is invalid", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      actor =
        actor_fixture(
          type: :account_admin_user,
          account: account,
          allow_email_otp_sign_in: true
        )

      # First, initiate sign-in to get a valid cookie
      conn =
        post(conn, ~p"/#{account.id}/sign_in/email_otp/#{provider.id}", %{
          "email" => %{"email" => actor.email}
        })

      # Now try to verify with wrong code
      conn =
        conn
        |> recycle_with_cookie()
        |> post(~p"/#{account.id}/sign_in/email_otp/#{provider.id}/verify", %{
          "secret" => "wrong1"
        })

      assert redirected_to(conn) =~ ~p"/#{account.id}/sign_in/email_otp/#{provider.id}"
      assert flash(conn, :error) =~ "invalid or expired"
    end

    test "redirects with error when passcode_id does not exist", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      # Set up cookie with a fake passcode_id and actor_id
      cookie = %PortalWeb.Cookie.EmailOTP{
        actor_id: Ecto.UUID.generate(),
        passcode_id: Ecto.UUID.generate(),
        email: "test@example.com"
      }

      conn =
        conn
        |> PortalWeb.Cookie.EmailOTP.put(cookie)
        |> recycle_with_cookie()
        |> post(~p"/#{account.id}/sign_in/email_otp/#{provider.id}/verify", %{
          "secret" => "123456"
        })

      assert redirected_to(conn) =~ ~p"/#{account.id}/sign_in/email_otp/#{provider.id}"
      assert flash(conn, :error) =~ "invalid or expired"
    end

    test "redirects with error when actor is disabled", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      actor =
        actor_fixture(
          type: :account_admin_user,
          account: account,
          allow_email_otp_sign_in: true
        )

      # Initiate sign-in to get a valid cookie and passcode
      conn =
        post(conn, ~p"/#{account.id}/sign_in/email_otp/#{provider.id}", %{
          "email" => %{"email" => actor.email}
        })

      # Get the code from the email
      assert_received {:email, email}
      code = extract_code_from_email(email)

      # Disable the actor
      actor
      |> Ecto.Changeset.change(disabled_at: DateTime.utc_now())
      |> Portal.Repo.update!()

      # Try to verify
      conn =
        conn
        |> recycle_with_cookie()
        |> post(~p"/#{account.id}/sign_in/email_otp/#{provider.id}/verify", %{
          "secret" => code
        })

      assert redirected_to(conn) =~ ~p"/#{account.id}"
      # Actor no longer has allow_email_otp_sign_in (due to being disabled)
      assert flash(conn, :error) =~ "The sign in code is invalid or expired."
    end

    test "redirects with error when actor no longer has allow_email_otp_sign_in", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      actor =
        actor_fixture(
          type: :account_admin_user,
          account: account,
          allow_email_otp_sign_in: true
        )

      # Initiate sign-in to get a valid cookie and passcode
      conn =
        post(conn, ~p"/#{account.id}/sign_in/email_otp/#{provider.id}", %{
          "email" => %{"email" => actor.email}
        })

      # Get the code from the email
      assert_received {:email, email}
      code = extract_code_from_email(email)

      # Remove allow_email_otp_sign_in
      actor
      |> Ecto.Changeset.change(allow_email_otp_sign_in: false)
      |> Portal.Repo.update!()

      # Try to verify
      conn =
        conn
        |> recycle_with_cookie()
        |> post(~p"/#{account.id}/sign_in/email_otp/#{provider.id}/verify", %{
          "secret" => code
        })

      assert redirected_to(conn) =~ ~p"/#{account.id}"
      # Actor no longer allowed to use email OTP sign-in
      assert flash(conn, :error) =~ "The sign in code is invalid or expired."
    end

    test "redirects with error when provider is disabled", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      actor =
        actor_fixture(
          type: :account_admin_user,
          account: account,
          allow_email_otp_sign_in: true
        )

      # Initiate sign-in to get a valid cookie and passcode
      conn =
        post(conn, ~p"/#{account.id}/sign_in/email_otp/#{provider.id}", %{
          "email" => %{"email" => actor.email}
        })

      # Get the code from the email
      assert_received {:email, email}
      code = extract_code_from_email(email)

      # Disable the provider
      provider
      |> Ecto.Changeset.change(is_disabled: true)
      |> Portal.Repo.update!()

      # Try to verify
      conn =
        conn
        |> recycle_with_cookie()
        |> post(~p"/#{account.id}/sign_in/email_otp/#{provider.id}/verify", %{
          "secret" => code
        })

      assert redirected_to(conn) == ~p"/#{account.id}"
      assert flash(conn, :error) =~ "You may not use this method to sign in"
    end

    test "redirects with error when code is already used", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      actor =
        actor_fixture(
          type: :account_admin_user,
          account: account,
          allow_email_otp_sign_in: true
        )

      # Initiate sign-in to get a valid cookie and passcode
      conn =
        post(conn, ~p"/#{account.id}/sign_in/email_otp/#{provider.id}", %{
          "email" => %{"email" => actor.email}
        })

      # Get the code from the email
      assert_received {:email, email}
      code = extract_code_from_email(email)

      # First verification should succeed
      conn =
        conn
        |> recycle_with_cookie()
        |> post(~p"/#{account.id}/sign_in/email_otp/#{provider.id}/verify", %{
          "secret" => code
        })

      # Should redirect to portal (browser context) - goes to sites page
      assert redirected_to(conn) =~ "/sites"

      # The cookie should have been deleted after successful verification
      state = get_cookie_state(conn)
      assert state == %{}
    end

    test "successfully authenticates admin user in browser context", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      actor =
        actor_fixture(
          type: :account_admin_user,
          account: account,
          allow_email_otp_sign_in: true
        )

      # Initiate sign-in
      conn =
        post(conn, ~p"/#{account.id}/sign_in/email_otp/#{provider.id}", %{
          "email" => %{"email" => actor.email}
        })

      # Get the code from the email
      assert_received {:email, email}
      code = extract_code_from_email(email)

      # Verify
      conn =
        conn
        |> recycle_with_cookie()
        |> post(~p"/#{account.id}/sign_in/email_otp/#{provider.id}/verify", %{
          "secret" => code
        })

      # Should redirect to portal - goes to sites page
      assert redirected_to(conn) =~ "/sites"

      # Cookie should be cleared after successful verification
      state = get_cookie_state(conn)
      assert state == %{}
    end

    test "successfully authenticates account_user in client context", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      actor =
        actor_fixture(
          type: :account_user,
          account: account,
          allow_email_otp_sign_in: true
        )

      # Initiate sign-in with client context
      conn =
        post(conn, ~p"/#{account.id}/sign_in/email_otp/#{provider.id}", %{
          "email" => %{"email" => actor.email},
          "as" => "client",
          "state" => "test-state",
          "nonce" => "test-nonce"
        })

      # Get the code from the email
      assert_received {:email, email}
      code = extract_code_from_email(email)

      # Verify with client context
      conn =
        conn
        |> recycle_with_cookie()
        |> post(~p"/#{account.id}/sign_in/email_otp/#{provider.id}/verify", %{
          "secret" => code,
          "as" => "client",
          "state" => "test-state",
          "nonce" => "test-nonce"
        })

      # Client context renders the client_redirect page (200) with a meta redirect
      assert conn.status == 200
      assert conn.resp_body =~ "client_redirect"

      # Email OTP cookie should be cleared
      state = get_cookie_state(conn)
      assert state == %{}
    end

    test "rejects account_user in browser context (portal requires admin)", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      actor =
        actor_fixture(
          type: :account_user,
          account: account,
          allow_email_otp_sign_in: true
        )

      # Initiate sign-in in browser context (no as=client)
      conn =
        post(conn, ~p"/#{account.id}/sign_in/email_otp/#{provider.id}", %{
          "email" => %{"email" => actor.email}
        })

      # Get the code from the email
      assert_received {:email, email}
      code = extract_code_from_email(email)

      # Verify in browser context
      conn =
        conn
        |> recycle_with_cookie()
        |> post(~p"/#{account.id}/sign_in/email_otp/#{provider.id}/verify", %{
          "secret" => code
        })

      # Should be rejected - account_user can't access portal
      assert redirected_to(conn) == ~p"/#{account.id}"
      assert flash(conn, :error) =~ "admin privileges"
    end
  end

  describe "verify/2 GET" do
    test "redirects with error when cookie is missing", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      conn =
        get(conn, ~p"/#{account.id}/sign_in/email_otp/#{provider.id}/verify", %{
          "secret" => "123456"
        })

      assert redirected_to(conn) == ~p"/#{account.id}"
      assert flash(conn, :error) =~ "missing or expired"
    end

    test "successfully authenticates via GET with valid code", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      actor =
        actor_fixture(
          type: :account_admin_user,
          account: account,
          allow_email_otp_sign_in: true
        )

      # Initiate sign-in
      conn =
        post(conn, ~p"/#{account.id}/sign_in/email_otp/#{provider.id}", %{
          "email" => %{"email" => actor.email}
        })

      # Get the code from the email
      assert_received {:email, email}
      code = extract_code_from_email(email)

      # Verify via GET (as if clicking link in email)
      conn =
        conn
        |> recycle_with_cookie()
        |> get(~p"/#{account.id}/sign_in/email_otp/#{provider.id}/verify", %{
          "secret" => code
        })

      # Should redirect to portal - goes to sites page
      assert redirected_to(conn) =~ "/sites"
    end

    test "redirects with error when code is invalid via GET", %{
      conn: conn,
      account: account,
      provider: provider
    } do
      actor =
        actor_fixture(
          type: :account_admin_user,
          account: account,
          allow_email_otp_sign_in: true
        )

      # Initiate sign-in
      conn =
        post(conn, ~p"/#{account.id}/sign_in/email_otp/#{provider.id}", %{
          "email" => %{"email" => actor.email}
        })

      # Verify via GET with wrong code
      conn =
        conn
        |> recycle_with_cookie()
        |> get(~p"/#{account.id}/sign_in/email_otp/#{provider.id}/verify", %{
          "secret" => "wrong1"
        })

      assert redirected_to(conn) =~ ~p"/#{account.id}/sign_in/email_otp/#{provider.id}"
      assert flash(conn, :error) =~ "invalid or expired"
    end
  end

  defp recycle_with_cookie(conn) do
    # Ensure response is sent before recycling cookies
    conn =
      if conn.state == :sent do
        conn
      else
        Plug.Conn.send_resp(conn, 200, "")
      end

    conn
    |> then(&Plug.Test.recycle_cookies(build_conn(), &1))
    |> Map.put(:secret_key_base, PortalWeb.Endpoint.config(:secret_key_base))
    |> Plug.Conn.fetch_cookies(signed: ["email_otp"])
  end

  # Helper to extract the OTP code from the email
  defp extract_code_from_email(email) do
    # The code is on its own line after "Copy and paste..."
    # It's 5 characters, URL-friendly (lowercase alphanumeric)
    case Regex.run(~r/\n([a-z0-9]{5})\n/, email.text_body) do
      [_, code] -> code
      _ -> raise "Could not extract code from email: #{email.text_body}"
    end
  end
end
