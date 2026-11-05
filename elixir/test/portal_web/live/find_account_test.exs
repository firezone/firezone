defmodule PortalWeb.FindAccountTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures

  describe "mount" do
    test "renders email input form", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/find_account")

      assert html =~ "Find your organization&#39;s account"
      assert html =~ "Work email"
      assert html =~ "Find"
    end
  end

  describe "validate_email" do
    test "shows validation error for invalid email format", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/find_account")

      html =
        lv
        |> form("form", email_form: %{email: "not-an-email"})
        |> render_change()

      assert html =~ "is an invalid email address"
    end
  end

  describe "submit_email" do
    test "valid email transitions to email sent step", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/find_account")

      html =
        lv
        |> form("form", email_form: %{email: "user@example.com"})
        |> render_submit()

      assert html =~ "Check your inbox"
      assert html =~ "user@example.com"
    end

    test "emails account sign-in links with account slugs", %{conn: conn} do
      email = "user@example.com"
      account = account_fixture()
      actor_fixture(account: account, email: email)

      {:ok, lv, _html} = live(conn, ~p"/find_account")

      html =
        lv
        |> form("form", email_form: %{email: email})
        |> render_submit()

      assert html =~ "Check your inbox"

      assert_email_sent(fn email ->
        assert email.text_body =~ "http://localhost:13100/#{account.slug}/sign_in"
        refute email.text_body =~ "http://localhost:13100/#{account.id}/sign_in"
        true
      end)
    end

    test "limits emails from one client IP across addresses", %{conn: conn} do
      Portal.Config.put_env_override(:portal, PortalWeb.PublicEmailRateLimit, per_ip_per_hour: 1)
      conn = Plug.Test.put_peer_data(conn, %{address: unique_ip(), port: 443, ssl_cert: nil})

      {:ok, lv, _html} = live(conn, ~p"/find_account")
      lv |> form("form", email_form: %{email: "first@example.com"}) |> render_submit()
      assert_email_sent(to: "first@example.com")

      {:ok, lv, _html} = live(conn, ~p"/find_account")

      html =
        lv
        |> form("form", email_form: %{email: "second@example.com"})
        |> render_submit()

      assert html =~ "Too many attempts"
      refute html =~ "Check your inbox"
      refute_email_sent()
    end

    test "invalid email stays on form with error", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/find_account")

      html =
        lv
        |> form("form", email_form: %{email: ""})
        |> render_submit()

      refute html =~ "Check your inbox"
    end
  end

  describe "turnstile" do
    setup %{conn: conn} do
      Portal.Config.put_env_override(:portal, Portal.Turnstile,
        site_key: "test-site-key",
        secret_key: "test-secret-key",
        req_opts: [retry: false, plug: {Req.Test, __MODULE__}]
      )

      conn = Plug.Test.put_peer_data(conn, %{address: unique_ip(), port: 443, ssl_cert: nil})
      {:ok, conn: conn, email: "find-#{System.unique_integer([:positive])}@example.com"}
    end

    defp stub_turnstile(result) do
      test_pid = self()

      Req.Test.stub(__MODULE__, fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(test_pid, {:cloudflare_request, URI.decode_query(body)})

        case result do
          :approve -> Req.Test.json(conn, %{"success" => true})
          :refuse -> Req.Test.json(conn, %{"success" => false, "error-codes" => ["invalid-input-response"]})
          :down -> Plug.Conn.send_resp(conn, 503, "unavailable")
        end
      end)
    end

    defp submit(lv, email, extra \\ %{}) do
      lv |> form("form", email_form: %{email: email}) |> render_submit(extra)
    end

    test "renders the widget and a token field inside the form", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/find_account")

      assert html =~ ~s(id="find-account-turnstile-widget")
      assert html =~ ~s(data-sitekey="test-site-key")
      assert has_element?(lv, "#find-account-form input[name=cf-turnstile-response][data-turnstile-token]")
    end

    test "renders no widget when no keys are configured", %{conn: conn} do
      Portal.Config.put_env_override(:portal, Portal.Turnstile, site_key: nil, secret_key: nil)

      {:ok, _lv, html} = live(conn, ~p"/find_account")

      refute html =~ "turnstile"
    end

    test "sends the email and gives Cloudflare the token and client IP", %{conn: conn, email: email} do
      stub_turnstile(:approve)
      {:ok, lv, _html} = live(conn, ~p"/find_account")

      html = submit(lv, email, %{"cf-turnstile-response" => "good-token"})

      assert html =~ "Check your inbox"
      assert_email_sent(to: email)
      assert_receive {:cloudflare_request, form}
      assert form["response"] == "good-token"
      assert form["secret"] == "test-secret-key"
      assert form["remoteip"] =~ ~r/^10\./
    end

    test "rejects a submission without a token and never calls Cloudflare", %{conn: conn, email: email} do
      stub_turnstile(:approve)
      {:ok, lv, _html} = live(conn, ~p"/find_account")

      html = submit(lv, email)

      assert has_element?(lv, "#turnstile-form-error", "Please complete the verification and try again.")
      refute html =~ "Check your inbox"
      refute_receive {:cloudflare_request, _}
      refute_email_sent()
    end

    test "rejects a token Cloudflare refuses and asks the widget for a new one", %{conn: conn, email: email} do
      stub_turnstile(:refuse)
      {:ok, lv, _html} = live(conn, ~p"/find_account")

      html = submit(lv, email, %{"cf-turnstile-response" => "bad-token"})

      assert html =~ "Please complete the verification and try again."
      assert_push_event(lv, "turnstile:reset", %{})
      refute_email_sent()
    end

    test "sends nothing while Cloudflare is unavailable", %{conn: conn, email: email} do
      stub_turnstile(:down)
      {:ok, lv, _html} = live(conn, ~p"/find_account")

      submit(lv, email, %{"cf-turnstile-response" => "good-token"})

      assert has_element?(lv, "#turnstile-form-error", "We couldn't verify your request right now.")
      assert_push_event(lv, "turnstile:reset", %{})
      refute_email_sent()
    end

    test "an invalid form is sent back without calling Cloudflare", %{conn: conn} do
      stub_turnstile(:approve)
      {:ok, lv, _html} = live(conn, ~p"/find_account")

      submit(lv, "not-an-email", %{"cf-turnstile-response" => "good-token"})

      refute has_element?(lv, "#turnstile-form-error")
      refute_receive {:cloudflare_request, _}
      refute_email_sent()
    end

    test "a refused token does not use up the IP limit", %{conn: conn, email: email} do
      Portal.Config.put_env_override(:portal, PortalWeb.PublicEmailRateLimit, per_ip_per_hour: 1)
      stub_turnstile(:refuse)
      {:ok, lv, _html} = live(conn, ~p"/find_account")
      submit(lv, email, %{"cf-turnstile-response" => "bad-token"})

      stub_turnstile(:approve)
      html = submit(lv, email, %{"cf-turnstile-response" => "good-token"})

      assert html =~ "Check your inbox"
      assert_email_sent(to: email)
    end

    test "the form-level error goes away once the form changes", %{conn: conn, email: email} do
      stub_turnstile(:refuse)
      {:ok, lv, _html} = live(conn, ~p"/find_account")
      submit(lv, email, %{"cf-turnstile-response" => "bad-token"})
      assert has_element?(lv, "#turnstile-form-error")

      lv |> form("form", email_form: %{email: email}) |> render_change()

      refute has_element?(lv, "#turnstile-form-error")
    end
  end

  defp unique_ip do
    {10, :rand.uniform(255), :rand.uniform(255), :rand.uniform(255)}
  end
end
