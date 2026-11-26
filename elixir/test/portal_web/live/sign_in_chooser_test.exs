defmodule PortalWeb.SignInChooserTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures

  @client_sign_in_types ["client", "gui-client", "headless-client"]

  describe "recent accounts" do
    test "shows no recent accounts without a cookie", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/sign_in")

      assert html =~ "Sign in"
      refute has_element?(lv, "#recent-accounts")
    end

    test "links each recent account's sign-in page, most recent first", %{conn: conn} do
      older = account_fixture()
      newer = account_fixture()

      {:ok, lv, html} =
        conn
        |> put_recent_accounts([newer.id, older.id])
        |> live(~p"/sign_in")

      assert has_element?(lv, "#recent-accounts a[href='/#{newer.slug}/sign_in']", newer.name)
      assert has_element?(lv, "#recent-accounts a[href='/#{older.slug}/sign_in']", older.name)
      assert :binary.match(html, newer.name) < :binary.match(html, older.name)
    end

    test "shows the remove button in place of the chevron, only on hover", %{conn: conn} do
      account = account_fixture()

      {:ok, lv, html} = conn |> put_recent_accounts([account.id]) |> live(~p"/sign_in")

      assert html =~ "Pick up where you left off or get a sign-in link by email."
      row = "#recent-account-#{account.id}"
      refute has_element?(lv, "#{row} .ri-arrow-right-s-line")
      assert has_element?(lv, "#{row}.group\\/row")

      [class] =
        lv |> element("#{row} form") |> render() |> Floki.parse_fragment!() |> Floki.attribute("class")

      assert class =~ "absolute"
      assert class =~ "opacity-0"
      assert class =~ "group-hover/row:opacity-100"
      assert class =~ "focus-within:opacity-100"
      assert class =~ "pointer-coarse:opacity-100"
    end

    test "removes a recent account with the form next to it", %{conn: conn} do
      [removed, kept] = [account_fixture(), account_fixture()]
      conn = put_recent_accounts(conn, [removed.id, kept.id])

      {:ok, lv, _html} = live(conn, ~p"/sign_in?#{%{"as" => "client"}}")

      button = "#recent-account-#{removed.id} form button[aria-label='Remove #{removed.name} from recent accounts']"
      assert has_element?(lv, button)

      # Send what the browser sends for that form: its method and action, unchanged.
      [form] =
        lv
        |> element("#recent-account-#{removed.id} form")
        |> render()
        |> Floki.parse_fragment!()

      assert Floki.attribute([form], "method") == ["post"]
      assert Floki.find([form], "input[name=_method]") == []
      [action] = Floki.attribute([form], "action")

      conn = post(conn, action)

      assert redirected_to(conn) == ~p"/sign_in?as=client"
      {:ok, lv, _html} = conn |> recycle() |> live(redirected_to(conn))
      refute has_element?(lv, "#recent-account-#{removed.id}")
      assert has_element?(lv, "#recent-account-#{kept.id}")
    end

    test "keeps the sign-in params on the account links", %{conn: conn} do
      account = account_fixture()

      {:ok, lv, _html} =
        conn
        |> put_recent_accounts([account.id])
        |> live(~p"/sign_in?#{%{"as" => "client", "state" => "abc"}}")

      assert has_element?(lv, "#recent-accounts a[href='/#{account.slug}/sign_in?as=client&state=abc']")
    end

    test "drops accounts that no longer exist from the cookie", %{conn: conn} do
      account = account_fixture()
      deleted_id = Ecto.UUID.generate()

      conn =
        conn
        |> put_recent_accounts([deleted_id, account.id])
        |> get(~p"/sign_in")

      html = html_response(conn, 200)
      assert html =~ account.name
      assert conn.private.recent_account_ids == [account.id]
      assert %{"recent_accounts" => _pruned} = conn.resp_cookies
    end

    test "sends home to sign-up once every recent account is gone", %{
      conn: conn
    } do
      conn = conn |> put_recent_accounts([Ecto.UUID.generate()]) |> get(~p"/sign_in")

      conn = conn |> recycle() |> get(~p"/")

      assert redirected_to(conn) == ~p"/sign_up"
    end

    test "leaves the cookie alone when every account exists", %{conn: conn} do
      account = account_fixture()

      conn = conn |> put_recent_accounts([account.id]) |> get(~p"/sign_in")

      refute Map.has_key?(conn.resp_cookies, "recent_accounts")
    end
  end

  describe "browser sign-in" do
    test "offers the email form, a hidden account ID form and sign-up", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/sign_in")

      assert html =~ "Enter your email and we&#39;ll send you a sign-in link."
      assert has_element?(lv, "#find-account-form")
      refute html =~ "Find your organizations"
      refute has_element?(lv, "#account-slug-section.border-t")
      assert has_element?(lv, "#account-slug-section #account-slug-prompt", "Know your sign-in URL?")
      assert has_element?(lv, "#account-slug-toggle", "Enter it instead")
      assert has_element?(lv, "#account-slug-section #sign-up-link.mt-1 a[href='/sign_up']", "Sign up")
      assert has_element?(lv, "#account-slug-prompt + #account-slug.mb-3 + #sign-up-link")

      [toggle_js] =
        lv
        |> element("#account-slug-toggle")
        |> render()
        |> Floki.parse_fragment!()
        |> Floki.attribute("phx-click")

      assert toggle_js =~ ~s("hide")
      assert toggle_js =~ "#account-slug-prompt"
      assert toggle_js =~ ~s("show")
      assert toggle_js =~ ~s("focus")
      refute has_element?(lv, "#account-slug-toggle", "Know your sign-in URL?")
      assert has_element?(lv, "#account-slug-toggle[aria-controls='account-slug']")
      assert has_element?(lv, "#account-slug.hidden form[action='/sign_in']")
      assert has_element?(lv, "a[href='/sign_up']", "Sign up")
    end

    test "shows an error from an invalid account ID", %{conn: conn} do
      conn = post(conn, ~p"/sign_in", %{"account_id_or_slug" => "?1"})

      {:ok, _lv, html} = conn |> recycle() |> live(redirected_to(conn))

      assert html =~ "Sign-in URLs can only contain letters, digits and underscores"
    end
  end

  describe "client sign-in" do
    test "shows the account ID form and nothing that leaves the client flow", %{conn: conn} do
      for client <- @client_sign_in_types do
        {:ok, lv, html} = live(conn, ~p"/sign_in?#{%{"as" => client}}")

        assert html =~ "Enter your organization&#39;s sign-in URL to continue."
        assert has_element?(lv, "#account-slug form[action='/sign_in?as=#{client}']")
        refute has_element?(lv, "#account-slug.hidden")
        refute has_element?(lv, "#account-slug-toggle")
        refute html =~ "Sign up"
      end
    end

    test "offers the email form behind a link below the sign-in URL form", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/sign_in?as=gui-client")

      assert has_element?(lv, "#account-slug + #client-email-section")
      assert has_element?(lv, "#client-email-prompt:not(.hidden)", "Forgot your sign-in URL?")
      assert has_element?(lv, "#client-email-toggle[aria-controls='client-email']", "Email it to me")
      refute has_element?(lv, "#client-email-toggle", "Forgot your sign-in URL?")
      assert has_element?(lv, "#client-email.hidden #find-account-form")

      [toggle_js] =
        html |> Floki.parse_document!() |> Floki.attribute("#client-email-toggle", "phx-click")

      assert toggle_js =~ "#client-email-prompt"
      assert toggle_js =~ ~s("show")
      assert toggle_js =~ ~s("focus")
    end

    test "keeps the email form open once something has been typed in it", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_in?as=gui-client")

      lv |> form("#find-account-form", email_form: %{email: "not-an-email"}) |> render_change()

      refute has_element?(lv, "#client-email.hidden")
      assert has_element?(lv, "#client-email-prompt.hidden")
    end

    test "emails the sign-in URLs to enter, not links, and shows the form to enter one", %{conn: conn} do
      email = "client-user@example.com"
      account = account_fixture()
      actor_fixture(account: account, email: email)

      {:ok, lv, _html} = live(conn, ~p"/sign_in?as=gui-client&state=s&nonce=n")

      html = lv |> form("#find-account-form", email_form: %{email: email}) |> render_submit()

      # The confirmation takes the email form's place; the page and its sign-in URL form stay.
      assert has_element?(lv, "#client-email-section #client-email-sent[role='status']", "Check your inbox")
      assert html =~ "is registered, we&#39;ve sent you your sign-in URL. Enter it above when it arrives."
      assert has_element?(lv, "#client-email-sent", email)
      refute has_element?(lv, "#find-account-form")
      refute has_element?(lv, "#client-email-prompt")
      assert has_element?(lv, "#account-slug form[action='/sign_in?as=gui-client&nonce=n&state=s']")
      assert has_element?(lv, "h1", "Sign in")
      refute html =~ "Sign up"

      assert_email_sent(fn sent ->
        assert sent.text_body =~ "    http://localhost:13100/#{account.slug}\n"
        assert sent.text_body =~ "the Firezone app opened"
        refute sent.text_body =~ "/sign_in"
        refute sent.html_body =~ "Sign In &rarr;"
        refute sent.text_body =~ "nonce"
        true
      end)
    end

    test "try again brings back the email form, open", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_in?as=gui-client")

      lv |> form("#find-account-form", email_form: %{email: "retry-client@example.com"}) |> render_submit()
      assert has_element?(lv, "#client-email-sent")

      lv |> element("#client-email-retry") |> render_click()

      refute has_element?(lv, "#client-email-sent")
      assert has_element?(lv, "#client-email:not(.hidden) #find-account-form")
      assert has_element?(lv, "#client-email-prompt.hidden")
      refute has_element?(lv, "#find-account-form input[value='retry-client@example.com']")
    end

    test "leaves sign-up out of the no-accounts email", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_in?as=gui-client")

      lv |> form("#find-account-form", email_form: %{email: "nobody-client@example.com"}) |> render_submit()

      assert_email_sent(fn sent ->
        assert sent.text_body =~ "We couldn't find any Firezone organization accounts"
        refute sent.text_body =~ "sign_up"
        refute sent.html_body =~ "sign_up"
        true
      end)
    end

    test "never links to sign-up, even with recent accounts", %{conn: conn} do
      account = account_fixture()

      for client <- @client_sign_in_types do
        {:ok, lv, html} =
          conn
          |> put_recent_accounts([account.id])
          |> live(~p"/sign_in?#{%{"as" => client}}")

        assert has_element?(lv, "#recent-account-#{account.id}")
        refute has_element?(lv, "a[href^='/sign_up']")
        refute html =~ "Sign up"
      end
    end
  end

  describe "validate_email" do
    test "shows validation error for invalid email format", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_in")

      html =
        lv
        |> form("#find-account-form", email_form: %{email: "not-an-email"})
        |> render_change()

      assert html =~ "is an invalid email address"
    end
  end

  describe "submit_email" do
    test "valid email transitions to email sent step", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_in")

      html =
        lv
        |> form("#find-account-form", email_form: %{email: "user@example.com"})
        |> render_submit()

      assert html =~ "Check your inbox"
      assert html =~ "user@example.com"
      assert html =~ "is registered, we&#39;ve sent you a sign-in link."
      assert html =~ "Click the sign-in link"
      refute html =~ "for each one"
      refute html =~ "ri-mail-send-line"
      refute html =~ "In more than one?"
    end

    test "try again goes back to the form", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_in")
      lv |> form("#find-account-form", email_form: %{email: "user@example.com"}) |> render_submit()

      lv |> element("a", "Try again") |> render_click()

      assert has_element?(lv, "#find-account-form")
      refute render(lv) =~ "Check your inbox"
    end

    test "emails account sign-in links with account slugs", %{conn: conn} do
      email = "user@example.com"
      account = account_fixture()
      actor_fixture(account: account, email: email)

      {:ok, lv, _html} = live(conn, ~p"/sign_in")

      html =
        lv
        |> form("#find-account-form", email_form: %{email: email})
        |> render_submit()

      assert html =~ "Check your inbox"

      assert_email_sent(fn email ->
        assert email.text_body =~ "http://localhost:13100/#{account.slug}/sign_in"
        refute email.text_body =~ "http://localhost:13100/#{account.id}/sign_in"
        assert email.html_body =~ "Sign In &rarr;"
        true
      end)
    end

    test "offers sign-up in the no-accounts email for browsers", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_in")

      lv |> form("#find-account-form", email_form: %{email: "nobody-browser@example.com"}) |> render_submit()

      assert_email_sent(fn sent ->
        assert sent.text_body =~ "Create an account: http://localhost:13100/sign_up"
        true
      end)
    end

    test "limits emails from one client IP across addresses", %{conn: conn} do
      Portal.Config.put_env_override(:portal, PortalWeb.PublicEmailRateLimit, per_ip_per_hour: 1)
      conn = Plug.Test.put_peer_data(conn, %{address: unique_ip(), port: 443, ssl_cert: nil})

      {:ok, lv, _html} = live(conn, ~p"/sign_in")
      lv |> form("#find-account-form", email_form: %{email: "first@example.com"}) |> render_submit()
      assert_email_sent(to: "first@example.com")

      {:ok, lv, _html} = live(conn, ~p"/sign_in")

      html =
        lv
        |> form("#find-account-form", email_form: %{email: "second@example.com"})
        |> render_submit()

      assert html =~ "Too many attempts"
      refute html =~ "Check your inbox"
      refute_email_sent()
    end

    test "invalid email stays on form with error", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/sign_in")

      html =
        lv
        |> form("#find-account-form", email_form: %{email: ""})
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
      lv |> form("#find-account-form", email_form: %{email: email}) |> render_submit(extra)
    end

    test "renders the widget and a token field inside the form", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/sign_in")

      assert html =~ ~s(id="find-account-turnstile-widget")
      assert html =~ ~s(data-sitekey="test-site-key")
      assert has_element?(lv, "#find-account-form input[name=cf-turnstile-response][data-turnstile-token]")
    end

    test "renders no widget when no keys are configured", %{conn: conn} do
      Portal.Config.put_env_override(:portal, Portal.Turnstile, site_key: nil, secret_key: nil)

      {:ok, _lv, html} = live(conn, ~p"/sign_in")

      refute html =~ "turnstile"
    end

    test "sends the email and gives Cloudflare the token and client IP", %{conn: conn, email: email} do
      stub_turnstile(:approve)
      {:ok, lv, _html} = live(conn, ~p"/sign_in")

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
      {:ok, lv, _html} = live(conn, ~p"/sign_in")

      html = submit(lv, email)

      assert has_element?(lv, "#turnstile-form-error", "Please complete the verification and try again.")
      refute html =~ "Check your inbox"
      refute_receive {:cloudflare_request, _}
      refute_email_sent()
    end

    test "rejects a token Cloudflare refuses and asks the widget for a new one", %{conn: conn, email: email} do
      stub_turnstile(:refuse)
      {:ok, lv, _html} = live(conn, ~p"/sign_in")

      html = submit(lv, email, %{"cf-turnstile-response" => "bad-token"})

      assert html =~ "Please complete the verification and try again."
      assert_push_event(lv, "turnstile:reset", %{})
      refute_email_sent()
    end

    test "sends nothing while Cloudflare is unavailable", %{conn: conn, email: email} do
      stub_turnstile(:down)
      {:ok, lv, _html} = live(conn, ~p"/sign_in")

      submit(lv, email, %{"cf-turnstile-response" => "good-token"})

      assert has_element?(lv, "#turnstile-form-error", "We couldn't verify your request right now.")
      assert_push_event(lv, "turnstile:reset", %{})
      refute_email_sent()
    end

    test "an invalid form is sent back without calling Cloudflare", %{conn: conn} do
      stub_turnstile(:approve)
      {:ok, lv, _html} = live(conn, ~p"/sign_in")

      submit(lv, "not-an-email", %{"cf-turnstile-response" => "good-token"})

      refute has_element?(lv, "#turnstile-form-error")
      refute_receive {:cloudflare_request, _}
      refute_email_sent()
    end

    test "a refused token does not use up the IP limit", %{conn: conn, email: email} do
      Portal.Config.put_env_override(:portal, PortalWeb.PublicEmailRateLimit, per_ip_per_hour: 1)
      stub_turnstile(:refuse)
      {:ok, lv, _html} = live(conn, ~p"/sign_in")
      submit(lv, email, %{"cf-turnstile-response" => "bad-token"})

      stub_turnstile(:approve)
      html = submit(lv, email, %{"cf-turnstile-response" => "good-token"})

      assert html =~ "Check your inbox"
      assert_email_sent(to: email)
    end

    test "the form-level error goes away once the form changes", %{conn: conn, email: email} do
      stub_turnstile(:refuse)
      {:ok, lv, _html} = live(conn, ~p"/sign_in")
      submit(lv, email, %{"cf-turnstile-response" => "bad-token"})
      assert has_element?(lv, "#turnstile-form-error")

      lv |> form("#find-account-form", email_form: %{email: email}) |> render_change()

      refute has_element?(lv, "#turnstile-form-error")
    end
  end

  defp put_recent_accounts(conn, account_ids) do
    cookie_conn =
      PortalWeb.Cookie.RecentAccounts.put(conn, %PortalWeb.Cookie.RecentAccounts{account_ids: account_ids})

    %{value: signed_value} = cookie_conn.resp_cookies["recent_accounts"]
    put_req_cookie(conn, "recent_accounts", signed_value)
  end

  defp unique_ip do
    {10, :rand.uniform(255), :rand.uniform(255), :rand.uniform(255)}
  end
end
