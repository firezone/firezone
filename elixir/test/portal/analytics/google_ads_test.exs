defmodule Portal.Analytics.GoogleAdsTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  alias Portal.Analytics
  alias Portal.Analytics.{GoogleAds, OpenAI}
  import Portal.AccountFixtures

  setup do
    Portal.Config.put_env_override(:portal, GoogleAds,
      customer_id: "3339175923",
      registration_conversion_action_id: "7754865801",
      subscription_conversion_action_id: "7754865804",
      client_id: "test-client",
      client_secret: "test-secret",
      refresh_token: "test-refresh-token",
      req_opts: [retry: false, plug: {Req.Test, __MODULE__}]
    )
    account = account_fixture(metadata: %{
      marketing_attribution: %{
        "marketing_allowed" => true,
        "captured_at" => System.os_time(:second),
        "gclid" => "google-click", "wbraid" => "google-braid", "oppref" => "openai-click"
      },
      stripe: %{billing_email: "jane.doe+team@gmail.com"}
    })
    %{account: account}
  end

  test "queues Google conversions even when OpenAI is disabled", %{account: account} do
    Portal.Config.put_env_override(:portal, OpenAI, api_key: nil)
    Analytics.registration_completed(account, %Portal.Actor{email: " Jane.Doe+Signup@GMAIL.COM "})
    assert [] = all_enqueued(worker: OpenAI)
    assert [%{args: %{"payload" => payload}}] = all_enqueued(worker: GoogleAds)
    assert payload["encoding"] == "HEX"
    assert [%{"operatingAccount" => %{"accountType" => "GOOGLE_ADS", "accountId" => "3339175923"},
      "productDestinationId" => "7754865801"}] = payload["destinations"]
    assert [event] = payload["events"]
    assert event["transactionId"] == "registration_#{account.id}"
    assert event["eventTimestamp"] == account.inserted_at |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
    assert event["eventSource"] == "WEB"
    assert event["adIdentifiers"] == %{"gclid" => "google-click", "wbraid" => "google-braid"}
    assert event["consent"] == %{"adUserData" => "CONSENT_GRANTED", "adPersonalization" => "CONSENT_GRANTED"}
    assert event["userData"] == %{"userIdentifiers" => [%{"emailAddress" => Analytics.hash_email("janedoe@gmail.com")}]}
    refute JSON.encode!(payload) =~ "@"
    refute JSON.encode!(payload) =~ "test-secret"
    refute JSON.encode!(payload) =~ "openai-click"
  end

  test "Team enrollment has its own destination and stable transaction", %{account: account} do
    Analytics.subscription_created(account, "sub_team_google", 1_800_000_000)
    Analytics.subscription_created(account, "sub_team_google", 1_800_000_000)
    assert [%{args: %{"payload" => payload}}] = all_enqueued(worker: GoogleAds)
    assert hd(payload["destinations"])["productDestinationId"] == "7754865804"
    assert hd(payload["events"])["transactionId"] == "team_sub_team_google"
    assert hd(payload["events"])["eventTimestamp"] == "2027-01-15T08:00:00.000Z"
    assert hd(payload["events"])["userData"]["userIdentifiers"] == [%{"emailAddress" => GoogleAds.hash_email(account.metadata.stripe.billing_email)}]
  end

  test "both platforms receive provider-specific hashes", %{account: account} do
    Portal.Config.put_env_override(:portal, OpenAI, api_key: "openai-test-key")
    Analytics.registration_completed(account, %Portal.Actor{email: "jane.doe+signup@gmail.com"})
    assert [%{args: %{"event" => openai}}] = all_enqueued(worker: OpenAI)
    assert [%{args: %{"payload" => google}}] = all_enqueued(worker: GoogleAds)
    assert openai["user"]["emails_sha256"] == [Analytics.hash_email("jane.doe+signup@gmail.com")]
    assert hd(google["events"])["userData"]["userIdentifiers"] == [%{"emailAddress" => Analytics.hash_email("janedoe@gmail.com")}]
  end

  test "an unavailable Google destination does not suppress OpenAI", %{account: account} do
    Portal.Config.put_env_override(:portal, OpenAI, api_key: "openai-test-key")
    Portal.Config.merge_env_override(:portal, GoogleAds, registration_conversion_action_id: nil)
    Analytics.registration_completed(account, %Portal.Actor{email: "ada@example.com"})
    assert [_] = all_enqueued(worker: OpenAI)
    assert [] = all_enqueued(worker: GoogleAds)
  end

  test "denied, unknown and expired consent suppress Google jobs", %{account: account} do
    for attribution <- [nil, %{"marketing_allowed" => false, "gclid" => "existing-click"},
      %{"marketing_allowed" => true, "captured_at" => 0}] do
      denied = put_in(account.metadata.marketing_attribution, attribution)
      Analytics.registration_completed(denied, %Portal.Actor{email: "ada@example.com"})
    end
    assert [] = all_enqueued(worker: GoogleAds)
  end

  test "missing credentials disables Google delivery", %{account: account} do
    Portal.Config.merge_env_override(:portal, GoogleAds, refresh_token: nil)
    Analytics.registration_completed(account, %Portal.Actor{email: "ada@example.com"})
    assert [] = all_enqueued(worker: GoogleAds)
  end

  test "hash-only matching works without a click ID and supports a manager account", %{account: account} do
    Portal.Config.merge_env_override(:portal, GoogleAds, login_customer_id: "1112223333")
    account = update_in(account.metadata.marketing_attribution, &Map.drop(&1, ~w[gclid wbraid]))
    Analytics.registration_completed(account, %Portal.Actor{email: "ada@example.com"})
    assert [%{args: %{"payload" => payload}}] = all_enqueued(worker: GoogleAds)
    refute Map.has_key?(hd(payload["events"]), "adIdentifiers")
    assert hd(payload["destinations"])["loginAccount"] == %{"accountType" => "GOOGLE_ADS", "accountId" => "1112223333"}
  end

  test "worker rechecks saved consent before any OAuth or Google request", %{account: account} do
    Analytics.registration_completed(account, %Portal.Actor{email: "ada@example.com"})
    assert [job] = all_enqueued(worker: GoogleAds)
    Analytics.update_marketing_attribution(account, %{"marketing_allowed" => false})
    assert :ok = GoogleAds.perform(job)
  end

  test "refreshes OAuth token and sends exact payload with retry-safe identifiers", %{account: account} do
    Analytics.registration_completed(account, %Portal.Actor{email: "ada@example.com"})
    assert [job] = all_enqueued(worker: GoogleAds)
    payload = job.args["payload"]
    for response_status <- [503, 200] do
      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.host == "oauth2.googleapis.com"
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert URI.decode_query(body) == %{
          "grant_type" => "refresh_token", "client_id" => "test-client",
          "client_secret" => "test-secret", "refresh_token" => "test-refresh-token"
        }
        Req.Test.json(conn, %{"access_token" => "fresh-token"})
      end)
      Req.Test.expect(__MODULE__, fn conn ->
        assert conn.host == "datamanager.googleapis.com"
        assert conn.request_path == "/v1/events:ingest"
        assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer fresh-token"]
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        assert JSON.decode!(body) == payload
        if response_status == 200, do: Req.Test.json(conn, %{"requestId" => "request-123"}),
          else: Plug.Conn.send_resp(conn, response_status, "unavailable")
      end)
      result = GoogleAds.perform(job)
      if response_status == 200, do: assert(result == :ok), else: assert(result == {:error, {:http_status, 503}})
    end
  end

  test "invalid OAuth credentials are not retried or logged in errors" do
    Req.Test.expect(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 400, "invalid grant: test-refresh-token") end)
    assert {:cancel, {:http_status, 400}} = GoogleAds.deliver(%{})
  end

  test "normalizes Gmail aliases while preserving other domains" do
    assert GoogleAds.hash_email(" Jane.Doe+Shopping@googlemail.com ") == Analytics.hash_email("janedoe@googlemail.com")
    assert GoogleAds.hash_email(" Jane.Doe+Shopping@Example.com ") == Analytics.hash_email("jane.doe+shopping@example.com")
  end
end
