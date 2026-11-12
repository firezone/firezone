defmodule PortalWeb.SignUpReviewTest do
  use PortalWeb.ConnCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures

  alias Portal.Mocks.Stripe
  alias Portal.Workers.SignUpReviewRequest
  alias PortalWeb.SignUpReview

  @sign_up_token_salt "sign_up_email_v1"
  @approvers ["alice@firezone.dev", "bob@firezone.dev"]

  setup do
    Portal.Config.put_env_override(:portal, SignUpReviewRequest, approvers: @approvers)

    Portal.Repo.insert!(%Portal.KnownMxDomain{domain: "known-mail.test"})
    :ok
  end

  describe "verify" do
    test "creates the account at once when every MX host is known", %{conn: conn} do
      stub_mx(["mx1.known-mail.test", "MX2.Known-Mail.Test."])
      email = unique_email()
      stub_stripe(email)

      conn = verify(conn, email)

      assert redirected_to(conn) =~ "/sites"
      assert Portal.Repo.get_by(Portal.Account, name: "Review Corp")
      assert [] == all_enqueued(worker: SignUpReviewRequest)
    end

    test "creates the account at once when review is off", %{conn: conn} do
      Portal.Config.put_env_override(:portal, SignUpReviewRequest, approvers: [])
      stub_mx(["mx.unknown.test"])
      email = unique_email()
      stub_stripe(email)

      conn = verify(conn, email)

      assert redirected_to(conn) =~ "/sites"
      assert Portal.Repo.get_by(Portal.Account, name: "Review Corp")
    end

    test "holds the sign-up and asks each approver when a host is unknown", %{conn: conn} do
      stub_mx(["mx.known-mail.test", "mx.unknown.test"])
      email = unique_email()

      conn = verify(conn, email)

      assert redirected_to(conn) == ~p"/sign_up/pending"
      refute Portal.Repo.get_by(Portal.Account, name: "Review Corp")

      jobs = all_enqueued(worker: SignUpReviewRequest)
      assert jobs |> Enum.map(& &1.args["approver"]) |> Enum.sort() == @approvers
      assert Enum.all?(jobs, &(&1.args["email"] == email))
      refute Enum.any?(jobs, &(&1.args["review"] =~ email))
    end

    test "does not match a host that only ends with the same characters", %{conn: conn} do
      stub_mx(["mx.notknown-mail.test"])
      assert redirected_to(verify(conn, unique_email())) == ~p"/sign_up/pending"
    end

    test "holds the sign-up when the domain has no MX records", %{conn: conn} do
      stub_resolve(fn _domain -> {:error, :nxdomain} end)
      assert redirected_to(verify(conn, unique_email())) == ~p"/sign_up/pending"
    end

    test "creates the account when a domain without MX records is itself known", %{conn: conn} do
      stub_mx([])
      email = "owner-#{System.unique_integer([:positive])}@mail.known-mail.test"
      stub_stripe(email)

      assert redirected_to(verify(conn, email)) =~ "/sites"
    end

    test "holds a domain without MX records as its own mail server", %{conn: conn} do
      email = hold_sign_up(conn, [])
      assert email =~ "@review.test"

      assert %{args: %{"review" => review}} = job_for("alice@firezone.dev")
      assert {:ok, %{mx_hosts: ["review.test"]}} = SignUpReview.decrypt_review(review)
    end

    test "holds an email without a domain", %{conn: conn} do
      stub_resolve(fn _domain -> flunk("no lookup expected") end)
      assert redirected_to(verify(conn, "no-at-sign")) == ~p"/sign_up/pending"
    end

    test "holds the sign-up when the domain has a null MX", %{conn: conn} do
      stub_mx(["."])
      assert redirected_to(verify(conn, unique_email())) == ~p"/sign_up/pending"
    end

    test "holds the sign-up when the MX lookup times out", %{conn: conn} do
      stub_resolve(fn _domain -> {:error, :timeout} end)
      assert redirected_to(verify(conn, unique_email())) == ~p"/sign_up/pending"
    end

    test "looks up the absolute domain name in lowercase ASCII", %{conn: conn} do
      test_pid = self()

      stub_resolve(fn domain ->
        send(test_pid, {:resolved, to_string(domain)})
        {:error, :nxdomain}
      end)

      verify(conn, "user@Bücher.Test")

      assert_received {:resolved, "xn--bcher-kva.test."}
    end

    test "asks only once per email for repeated verifications", %{conn: conn} do
      stub_mx(["mx.unknown.test"])
      email = unique_email()

      verify(conn, email)
      verify(build_conn(), email)

      assert length(all_enqueued(worker: SignUpReviewRequest)) == 2
    end

    test "sends an existing owner to sign in without a review", %{conn: conn} do
      stub_mx(["mx.unknown.test"])
      email = unique_email()
      account = account_fixture(metadata: %{stripe: %{billing_email: email}})

      conn = verify(conn, email)

      assert redirected_to(conn) == ~p"/#{account}/sign_in"
      assert [] == all_enqueued(worker: SignUpReviewRequest)
    end

    test "shows the pending page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/sign_up/pending")
      assert html =~ "Thanks for signing up"
      assert html =~ "up to 24 hours"
    end
  end

  describe "SignUpReviewRequest" do
    test "emails each approver a personal link", %{conn: conn} do
      email = hold_sign_up(conn)
      job = job_for("alice@firezone.dev")

      assert :ok = perform_job(SignUpReviewRequest, job.args)

      assert_email_sent(fn sent ->
        assert sent.to == [{"", "alice@firezone.dev"}]
        assert sent.reply_to == {"Review User", email}
        assert sent.subject == "Approve sign-up: Review Corp"
        assert sent.text_body =~ "Mail servers: mx.unknown.test"
        assert sent.text_body =~ "/sign_up/review?token="
        true
      end)
    end

    test "sends nothing to a removed approver", %{conn: conn} do
      hold_sign_up(conn)
      Portal.Config.put_env_override(:portal, SignUpReviewRequest, approvers: ["bob@firezone.dev"])

      assert :ok = perform_job(SignUpReviewRequest, job_for("alice@firezone.dev").args)
      refute_email_sent()
    end
  end

  describe "approval page" do
    test "approving trusts the selected domains, creates the account and tells all approvers",
         %{conn: conn} do
      email = hold_sign_up(conn, ["mx1.mail.unknown.test", "mx2.mail.unknown.test", "mx.known-mail.test"])
      stub_stripe(email)

      {:ok, lv, html} = live(conn, approval_path("alice@firezone.dev"))
      assert html =~ email
      assert html =~ "mail.unknown.test"
      refute html =~ ~s(value="known-mail.test")
      refute Portal.Repo.get_by(Portal.Account, name: "Review Corp")

      html = lv |> form("#sign-up-review-form", %{"domains" => ["mail.unknown.test"]}) |> render_submit()

      assert html =~ "Sign-up approved"
      account = Portal.Repo.get_by!(Portal.Account, name: "Review Corp")
      assert Portal.Repo.get(Portal.KnownMxDomain, "mail.unknown.test")

      assert_email_sent(fn sent ->
        assert sent.to == [{"", email}]
        assert sent.subject == "Welcome to Firezone"
        true
      end)

      assert [job] = all_enqueued(worker: Portal.Workers.OutboundEmail)
      assert job.args["account_id"] == account.id
      request = job.args["request"]
      assert Enum.map(request["to"], & &1["address"]) == @approvers
      assert request["subject"] == "Sign-up approved: Review Corp"
      assert request["text_body"] =~ "Approved by: alice@firezone.dev"
      assert request["text_body"] =~ "Newly trusted mail server domains: mail.unknown.test"
    end

    test "approving with no domain selected trusts nothing", %{conn: conn} do
      email = hold_sign_up(conn)
      stub_stripe(email)

      {:ok, lv, _html} = live(conn, approval_path("alice@firezone.dev"))
      render_submit(lv, "approve", %{})

      assert Portal.Repo.get_by!(Portal.Account, name: "Review Corp")
      refute Portal.Repo.get(Portal.KnownMxDomain, "unknown.test")
    end

    test "ignores domains that were not suggested", %{conn: conn} do
      email = hold_sign_up(conn)
      stub_stripe(email)

      {:ok, lv, _html} = live(conn, approval_path("alice@firezone.dev"))
      render_submit(lv, "approve", %{"domains" => ["amazonaws.com", "unknown.test"]})

      refute Portal.Repo.get(Portal.KnownMxDomain, "amazonaws.com")
      assert Portal.Repo.get(Portal.KnownMxDomain, "unknown.test")
    end

    test "suggests the host when its parent is a public suffix", %{conn: conn} do
      hold_sign_up(conn, ["mail.co.uk"])

      {:ok, _lv, html} = live(conn, approval_path("alice@firezone.dev"))

      assert html =~ ~s(value="mail.co.uk")
      refute html =~ ~s(value="co.uk")
    end

    test "a second approval reports the existing account", %{conn: conn} do
      email = hold_sign_up(conn)
      stub_stripe(email)
      path = approval_path("alice@firezone.dev")

      {:ok, first, _html} = live(conn, path)
      {:ok, second, _html} = live(build_conn(), path)
      render_submit(first, "approve", %{})

      assert render_submit(second, "approve", %{}) =~ "Already approved"
      assert [_account] = Portal.Repo.all_by(Portal.Account, name: "Review Corp")
    end

    test "rejects a link whose approver was removed", %{conn: conn} do
      hold_sign_up(conn)
      path = approval_path("alice@firezone.dev")
      Portal.Config.put_env_override(:portal, SignUpReviewRequest, approvers: ["bob@firezone.dev"])

      {:ok, _lv, html} = live(conn, path)
      assert html =~ "Link not valid"
    end

    test "rejects a tampered or missing token", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/sign_up/review?token=nope")
      assert html =~ "Link not valid"

      {:ok, _lv, html} = live(conn, ~p"/sign_up/review")
      assert html =~ "Link not valid"
    end
  end

  defp hold_sign_up(conn, mx_hosts \\ ["mx.unknown.test"]) do
    stub_mx(mx_hosts)
    email = unique_email()
    assert redirected_to(verify(conn, email)) == ~p"/sign_up/pending"
    email
  end

  defp approval_path(approver) do
    %URI{path: path, query: query} = URI.parse(SignUpReview.approval_url(job_for(approver).args["review"], approver))
    "#{path}?#{query}"
  end

  defp job_for(approver) do
    Enum.find(all_enqueued(worker: SignUpReviewRequest), &(&1.args["approver"] == approver))
  end

  defp verify(conn, email) do
    conn = get(conn, ~p"/sign_up")
    {conn, browser_id} = {recycle(conn), conn.private.sign_up_browser_id}

    claims = %{
      email: email,
      company_name: "Review Corp",
      actor_name: "Review User",
      browser: PortalWeb.Cookie.SignUpBrowser.token_claim(browser_id)
    }

    token = Phoenix.Token.sign(PortalWeb.Endpoint, @sign_up_token_salt, claims)
    post(conn, ~p"/verify_sign_up", %{"token" => token})
  end

  defp stub_mx(hosts) do
    records =
      Enum.map(hosts, fn host ->
        :inet_dns.make_rr(domain: ~c"example.test", type: :mx, class: :in, data: {10, String.to_charlist(host)})
      end)

    stub_resolve(fn _domain -> {:ok, :inet_dns.make_msg(anlist: records)} end)
  end

  defp stub_resolve(fun) do
    Portal.Config.put_env_override(:portal, SignUpReview, resolve_mx: fun)
  end

  defp stub_stripe(email) do
    Stripe.stub(
      [{"POST", "/v1/customers", 200, Stripe.customer_object("cus_test", "Review Corp", email)}] ++
        Stripe.mock_create_subscription_endpoint()
    )
  end

  defp unique_email, do: "owner-#{System.unique_integer([:positive])}@review.test"
end
