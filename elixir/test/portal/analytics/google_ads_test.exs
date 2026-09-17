defmodule Portal.Analytics.GoogleAdsTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  alias Portal.Analytics
  alias Portal.Analytics.{GoogleAds, OpenAI}
  import Portal.AccountFixtures

  setup do
    Portal.Config.put_env_override(:portal, GoogleAds,
      customer_id: "1234567890",
      registration_conversion_action_id: "1111111111",
      subscription_conversion_action_id: "2222222222",
      service_account_email: "ads@test-project.iam.gserviceaccount.com",
      workload_identity_provider: "//iam.googleapis.com/projects/123/locations/global/workloadIdentityPools/portal/providers/azure",
      workload_identity_audience: "api://portal-google",
      req_opts: [retry: false, plug: {Req.Test, __MODULE__}]
    )
    Portal.Config.merge_env_override(:portal, Portal.Google.APIClient,
      token_cache: :no_google_ads_test_cache,
      sts_endpoint: "https://sts.googleapis.com/v1/token",
      iam_credentials_endpoint: "https://iamcredentials.googleapis.com",
      req_opts: [retry: false, plug: {Req.Test, __MODULE__}]
    )
    Portal.Config.merge_env_override(:portal, Portal.Azure.ManagedIdentity,
      token_cache: :no_azure_ads_test_cache,
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
    assert [%{"operatingAccount" => %{"accountType" => "GOOGLE_ADS", "accountId" => "1234567890"},
      "productDestinationId" => "1111111111"}] = payload["destinations"]
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
    assert hd(payload["destinations"])["productDestinationId"] == "2222222222"
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
    Portal.Config.merge_env_override(:portal, GoogleAds, service_account_email: nil)
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

  test "worker rechecks saved consent before any identity or Google request", %{account: account} do
    Analytics.registration_completed(account, %Portal.Actor{email: "ada@example.com"})
    assert [job] = all_enqueued(worker: GoogleAds)
    Analytics.update_marketing_attribution(account, %{"marketing_allowed" => false})
    assert :ok = GoogleAds.perform(job)
  end

  test "federates the managed identity and sends exact payload with retry-safe identifiers", %{account: account} do
    Analytics.registration_completed(account, %Portal.Actor{email: "ada@example.com"})
    assert [job] = all_enqueued(worker: GoogleAds)
    payload = job.args["payload"]
    for response_status <- [503, 200] do
      expect_federation()
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

  test "federation denial cancels without leaking identity tokens" do
    expect_managed_identity()
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.host == "sts.googleapis.com"
      Plug.Conn.send_resp(conn, 403, "denied: azure-token")
    end)
    assert {:cancel, {:http_status, 403}} = GoogleAds.deliver(%{})
  end

  test "missing runtime configuration disables both providers", %{account: account} do
    Portal.Config.put_env_override(:portal, GoogleAds, [])
    Portal.Config.put_env_override(:portal, OpenAI, api_key: "key", pixel_id: nil)
    Analytics.registration_completed(account, %Portal.Actor{email: "ada@example.com"})
    assert [] = all_enqueued(worker: GoogleAds)
    assert [] = all_enqueued(worker: OpenAI)
  end

  test "caches scoped service-account tokens separately by identity and scope" do
    cache = start_supervised!({Portal.TokenCache, name: :"ads_cache_#{System.unique_integer([:positive])}"})
    Portal.Config.merge_env_override(:portal, Portal.Google.APIClient, token_cache: cache)
    Req.Test.allow(__MODULE__, self(), cache)
    identity = Portal.Config.fetch_env!(:portal, GoogleAds)
      |> Keyword.take([:service_account_email, :workload_identity_provider, :workload_identity_audience])
    scope = "https://www.googleapis.com/auth/datamanager"
    expect_managed_identity()
    expect_sts()
    expect_service_account("ads@test-project.iam.gserviceaccount.com", scope)
    assert {:ok, "fresh-token"} = Portal.Google.APIClient.get_service_account_access_token(identity, scope)
    assert {:ok, "fresh-token"} = Portal.Google.APIClient.get_service_account_access_token(identity, scope)
    expect_service_account("other@test-project.iam.gserviceaccount.com", scope)
    assert {:ok, "fresh-token"} = Portal.Google.APIClient.get_service_account_access_token(Keyword.put(identity, :service_account_email, "other@test-project.iam.gserviceaccount.com"), scope)
    expect_service_account("ads@test-project.iam.gserviceaccount.com", "another-scope")
    assert {:ok, "fresh-token"} = Portal.Google.APIClient.get_service_account_access_token(identity, "another-scope")
  end

  defp expect_federation do
    expect_managed_identity()
    expect_sts()
    expect_service_account("ads@test-project.iam.gserviceaccount.com", "https://www.googleapis.com/auth/datamanager")
  end

  defp expect_managed_identity do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.request_path == "/metadata/identity/oauth2/token"
      assert URI.decode_query(conn.query_string)["resource"] == "api://portal-google"
      Req.Test.json(conn, %{"access_token" => "azure-token", "expires_on" => Integer.to_string(System.os_time(:second) + 3600)})
    end)
  end

  defp expect_sts do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.host == "sts.googleapis.com"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert URI.decode_query(body) == %{
        "audience" => "//iam.googleapis.com/projects/123/locations/global/workloadIdentityPools/portal/providers/azure",
        "grant_type" => "urn:ietf:params:oauth:grant-type:token-exchange",
        "requested_token_type" => "urn:ietf:params:oauth:token-type:access_token",
        "scope" => "https://www.googleapis.com/auth/cloud-platform",
        "subject_token" => "azure-token",
        "subject_token_type" => "urn:ietf:params:oauth:token-type:jwt"
      }
      Req.Test.json(conn, %{"access_token" => "federated-token", "expires_in" => 3600})
    end)
  end

  defp expect_service_account(email, scope) do
    Req.Test.expect(__MODULE__, fn conn ->
      assert conn.host == "iamcredentials.googleapis.com"
      assert conn.request_path == "/v1/projects/-/serviceAccounts/#{email}:generateAccessToken"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer federated-token"]
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      assert JSON.decode!(body) == %{"scope" => [scope], "lifetime" => "3600s"}
      Req.Test.json(conn, %{"accessToken" => "fresh-token", "expireTime" => DateTime.utc_now() |> DateTime.add(3600) |> DateTime.to_iso8601()})
    end)
  end

  test "normalizes Gmail aliases while preserving other domains" do
    assert GoogleAds.hash_email(" Jane.Doe+Shopping@googlemail.com ") == Analytics.hash_email("janedoe@googlemail.com")
    assert GoogleAds.hash_email(" Jane.Doe+Shopping@Example.com ") == Analytics.hash_email("jane.doe+shopping@example.com")
  end
end
