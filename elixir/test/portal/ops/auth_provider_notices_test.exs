defmodule Portal.Ops.AuthProviderNoticesTest do
  use Portal.DataCase, async: true

  import ExUnit.CaptureIO
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.AuthProviderFixtures
  import Portal.IdentityFixtures
  import Portal.OutboundEmailTestHelpers

  alias Portal.Ops

  @configured_tenant "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
  @missing_tenant "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
  @other_tenant "cccccccc-cccc-cccc-cccc-cccccccccccc"

  test "Entra call prompts once and queues separate, escaped notices for current admins" do
    first = entra_account(name: "First <script>team</script>")
    second = entra_account(name: "Second Company", tenant: @other_tenant)
    disabled = admin_actor_fixture(account: first.account)
    Repo.update!(Ecto.Changeset.change(disabled, is_disabled: true))
    identity_fixture(account: first.account, issuer: entra_issuer(@configured_tenant))

    output = capture_io("y\n", fn -> assert :ok = Ops.notify_entra_auth_provider_admins() end)

    assert length(Regex.scan(~r/Continue\?/, output)) == 1
    assert output =~ first.admin.email
    assert output =~ second.admin.email
    refute output =~ disabled.email

    [first_email] = collect_queued_emails(first.account.id)
    [second_email] = collect_queued_emails(second.account.id)
    assert first_email.bcc == [{"", String.downcase(first.admin.email)}]
    assert second_email.bcc == [{"", String.downcase(second.admin.email)}]
    assert first_email.html_body =~ "First &lt;script&gt;team&lt;/script&gt;"
    refute first_email.html_body =~ "<script>"
    assert first_email.reply_to == [{"", "support@firezone.dev"}]
    assert first_email.html_body =~ "logo-dark"
    assert first_email.html_body =~ "prefers-color-scheme: dark"
    refute first_email.html_body =~ "Turn off these notifications"

    for body <- [first_email.html_body, first_email.text_body] do
      assert body =~ @missing_tenant
      refute body =~ @other_tenant
      refute body =~ @configured_tenant
      assert body =~ "Verify another tenant"
      assert body =~ "/#{first.account.slug}/settings/authentication"
    end

    for body <- [second_email.html_body, second_email.text_body] do
      assert body =~ @other_tenant
      refute body =~ @missing_tenant
      assert body =~ "/#{second.account.slug}/settings/authentication"
    end
  end

  test "Entra skips a tenant already allowed by another enabled provider" do
    %{account: account} = entra_account()
    entra_provider_fixture(account: account, name: "Other Entra", tenant_ids: [@missing_tenant])

    output = capture_io(fn ->
      assert {:error, :no_recipients} = Ops.notify_entra_auth_provider_admins()
    end)

    refute output =~ "Continue?"
    assert collect_queued_emails(account.id) == []
  end

  test "Entra deduplicates multiple missing tenants and stops notifying once they are allowed" do
    %{account: account, provider: provider} = entra_account()
    identity_fixture(account: account, issuer: entra_issuer(@missing_tenant), email: "another@partner.example")
    identity_fixture(account: account, issuer: entra_issuer(@other_tenant), email: "user@other.example")

    capture_io("y\n", fn -> assert :ok = Ops.notify_entra_auth_provider_admins([account.id]) end)
    [email] = collect_queued_emails(account.id)
    for body <- [email.html_body, email.text_body], tenant <- [@missing_tenant, @other_tenant] do
      assert length(String.split(body, tenant)) == 2
    end

    Repo.update!(Ecto.Changeset.change(provider, tenant_ids: [@configured_tenant, @missing_tenant, @other_tenant]))
    capture_io(fn ->
      assert {:error, :no_recipients} = Ops.notify_entra_auth_provider_admins([account.id])
    end)
    assert [_] = collect_queued_emails(account.id)
  end

  test "a disabled matching Entra provider does not hide a missing tenant" do
    %{account: account} = entra_account()
    entra_provider_fixture(account: account, name: "Disabled Entra",
      tenant_ids: [@missing_tenant], is_disabled: true)

    capture_io("y\n", fn -> assert :ok = Ops.notify_entra_auth_provider_admins() end)
    assert [%{text_body: body}] = collect_queued_emails(account.id)
    assert body =~ @missing_tenant
  end

  test "Google selects business identities, includes Gmail admins, and keeps domains unset" do
    first = google_account(name: "First Workspace", email: "User@WORK.EXAMPLE", admin_email: "admin@gmail.com")
    second = google_account(name: "Second Workspace", email: "user@other.example", issuer: "accounts.google.com")
    identity_fixture(account: first.account, issuer: "https://accounts.google.com", email: "personal@googlemail.com")
    identity_fixture(account: first.account, issuer: "https://accounts.google.com", email: "colleague@work.example")

    output = capture_io("y\n", fn -> assert :ok = Ops.notify_google_auth_provider_admins() end)

    assert length(Regex.scan(~r/Continue\?/, output)) == 1
    assert output =~ "admin@gmail.com"
    [first_email] = collect_queued_emails(first.account.id)
    [second_email] = collect_queued_emails(second.account.id)
    assert first_email.bcc == [{"", "admin@gmail.com"}]
    assert first_email.reply_to == [{"", "support@firezone.dev"}]

    for body <- [first_email.html_body, first_email.text_body] do
      assert body =~ "First Workspace"
      refute body =~ "Second Workspace"
      assert body =~ "security improvement"
      assert body =~ "This is optional."
      assert body =~ "Verify Now"
      refute body =~ "personal"
      refute body =~ "consumer"
      assert body =~ "/#{first.account.slug}/settings/authentication"
    end

    for body <- [second_email.html_body, second_email.text_body] do
      assert body =~ "Second Workspace"
      refute body =~ "First Workspace"
      assert body =~ "Verify another"
      refute body =~ "personal"
    end

    assert Repo.reload!(first.provider).workspace_domains == nil
    assert Repo.reload!(second.provider).workspace_domains == nil
  end

  test "Google excludes consumer-only identities, personal-only providers, and providers already restricted" do
    consumers = for domain <- ~w[gmail.com googlemail.com hotmail.com outlook.com yahoo.com icloud.com qq.com] do
      google_account(email: "personal@#{domain}")
    end
    restricted = google_account(workspace_domains: ["work.example"])
    wrong_issuer = google_account(issuer: entra_issuer(@configured_tenant))
    personal = google_account()
    Repo.update!(Ecto.Changeset.change(personal.provider, is_legacy_unrestricted: false))

    output = capture_io(fn ->
      assert {:error, :no_recipients} = Ops.notify_google_auth_provider_admins()
    end)

    refute output =~ "Continue?"
    for entry <- consumers ++ [restricted, wrong_issuer, personal] do
      assert collect_queued_emails(entry.account.id) == []
    end
  end

  for type <- [:entra, :google] do
    @provider type

    test "#{type} excludes disabled providers, accounts, identities, and accounts being deleted" do
      no_provider = notice_account(@provider)
      Repo.update!(Ecto.Changeset.change(no_provider.provider, is_disabled: true))
      disabled_account = notice_account(@provider)
      Repo.update!(Ecto.Changeset.change(disabled_account.account, is_disabled: true))
      deleting = notice_account(@provider)
      Repo.update!(Ecto.Changeset.change(deleting.account, scheduled_deletion_at: DateTime.utc_now()))
      disabled_actor = notice_account(@provider)
      Repo.update!(Ecto.Changeset.change(disabled_actor.identity.actor, is_disabled: true))

      capture_io(fn -> assert {:error, :no_recipients} = notify(@provider) end)
      for entry <- [no_provider, disabled_account, deleting, disabled_actor] do
        assert collect_queued_emails(entry.account.id) == []
      end
    end

    test "#{type} supports one account at a time and aborts without queuing" do
      first = notice_account(@provider)
      second = notice_account(@provider)
      output = capture_io("n\n", fn -> assert :aborted = notify(@provider, [first.account.id]) end)
      assert output =~ first.admin.email
      refute output =~ second.admin.email
      assert collect_queued_emails(first.account.id) == []
      assert collect_queued_emails(second.account.id) == []

      capture_io("y\n", fn -> assert :ok = notify(@provider, [first.account.id]) end)
      assert [_] = collect_queued_emails(first.account.id)
      assert collect_queued_emails(second.account.id) == []
    end

    test "#{type} preserves dormant-account filtering and paid-account eligibility" do
      paid = notice_account(@provider)
      dormant = notice_account(@provider, account: account_fixture())
      output = capture_io("y\n", fn -> assert :ok = notify(@provider) end)
      assert output =~ "Skipping 1 dormant account(s)"
      assert [_] = collect_queued_emails(paid.account.id)
      assert collect_queued_emails(dormant.account.id) == []
    end
  end

  test "tailored notices preserve BCC limits and shared send windows" do
    first = google_account()
    second = google_account()
    for entry <- [first, second], index <- 1..59 do
      admin_actor_fixture(account: entry.account, email: "admin-#{entry.account.id}-#{index}@example.com")
    end

    capture_io("y\n", fn -> assert :ok = Ops.notify_google_auth_provider_admins() end)
    jobs = [worker: Portal.Workers.OutboundEmail] |> Oban.Job.query() |> Repo.all()
    assert length(jobs) == 4
    assert Enum.all?(jobs, &(length(&1.args["request"]["bcc"]) <= 50))
    for entry <- [first, second] do
      account_jobs = Enum.filter(jobs, &(&1.args["account_id"] == entry.account.id))
      assert Enum.sum(Enum.map(account_jobs, &length(&1.args["request"]["bcc"]))) == 60
      assert length(Enum.uniq(Enum.map(account_jobs, & &1.scheduled_at))) == 1
    end
    assert Enum.sort(Enum.uniq(Enum.map(jobs, & &1.state))) == ["available", "scheduled"]
  end

  defp entra_account(opts \\ []) do
    account = Keyword.get_lazy(opts, :account, fn -> team_account_fixture(name: Keyword.get(opts, :name, "Entra Company")) end)
    admin = admin_actor_fixture(account: account)
    provider = entra_provider_fixture(account: account, tenant_ids: [@configured_tenant])
    identity = identity_fixture(account: account, issuer: entra_issuer(Keyword.get(opts, :tenant, @missing_tenant)), email: "user@partner.example")
    %{account: account, admin: admin, provider: provider, identity: identity}
  end

  defp google_account(opts \\ []) do
    account = Keyword.get_lazy(opts, :account, fn -> team_account_fixture(name: Keyword.get(opts, :name, "Google Company")) end)
    admin = admin_actor_fixture(account: account, email: Keyword.get(opts, :admin_email, "admin-#{account.id}@company.example"))
    provider = google_provider_fixture(account: account, workspace_domains: Keyword.get(opts, :workspace_domains),
      is_legacy_unrestricted: is_nil(Keyword.get(opts, :workspace_domains)))
    identity = identity_fixture(account: account, issuer: Keyword.get(opts, :issuer, "https://accounts.google.com"), email: Keyword.get(opts, :email, "user@work.example"))
    %{account: account, admin: admin, provider: provider, identity: identity}
  end

  defp notice_account(type, opts \\ [])
  defp notice_account(:entra, opts), do: entra_account(opts)
  defp notice_account(:google, opts), do: google_account(opts)
  defp notify(:entra), do: Ops.notify_entra_auth_provider_admins()
  defp notify(:google), do: Ops.notify_google_auth_provider_admins()
  defp notify(:entra, ids), do: Ops.notify_entra_auth_provider_admins(ids)
  defp notify(:google, ids), do: Ops.notify_google_auth_provider_admins(ids)
  defp entra_issuer(tenant), do: "https://login.microsoftonline.com/#{tenant}/v2.0"
end
