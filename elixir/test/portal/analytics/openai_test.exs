defmodule Portal.Analytics.OpenAITest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  alias Portal.Analytics
  alias Portal.Analytics.OpenAI
  import Portal.AccountFixtures

  setup do
    Portal.Config.put_env_override(:portal, OpenAI,
      api_key: "test-key",
      req_opts: [retry: false, plug: {Req.Test, __MODULE__}]
    )

    account = account_fixture(metadata: %{
      marketing_attribution: %{
        "marketing_allowed" => true,
        "captured_at" => System.os_time(:second),
        "oppref" => "original-click-reference"
      },
      stripe: %{billing_email: " ADA@Example.com "}
    })

    %{account: account}
  end

  test "registration queues a hashed conversion and retries preserve its payload", %{account: account} do
    actor = %Portal.Actor{email: " ADA@Example.com "}
    assert :ok = Analytics.registration_completed(account, actor)
    assert :ok = Analytics.registration_completed(account, actor)
    assert [%{args: %{"event" => event}}] = all_enqueued(worker: OpenAI)
    assert event["id"] == "registration_#{account.id}"
    assert event["type"] == "registration_completed"
    assert event["data"] == %{"type" => "customer_action"}
    assert event["oppref"] == "original-click-reference"
    assert event["user"] == %{"emails_sha256" => [Analytics.hash_email("ada@example.com")]}
    refute JSON.encode!(event) =~ "ada@example.com"

    test_pid = self()
    Req.Test.expect(__MODULE__, 2, fn conn ->
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer test-key"]
      assert Plug.Conn.fetch_query_params(conn).query_params["pid"] == "3b8jrA5hEKwRPyD15bYfAQ"
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:payload, JSON.decode!(body)})
      Plug.Conn.send_resp(conn, 503, "unavailable")
    end)

    for _ <- 1..2 do
      assert {:error, {:http_status, 503}} = OpenAI.deliver(event)
      assert_receive {:payload, %{"events" => [^event], "integration_source" => "firezone-portal"}}
    end
  end

  test "Team enrollment uses billing email and the plan enrollment shape", %{account: account} do
    assert :ok = Analytics.subscription_created(account, "sub_team", 1_800_000_000)
    assert [%{args: %{"event" => event}}] = all_enqueued(worker: OpenAI)
    assert event["type"] == "subscription_created"
    assert event["data"] == %{"type" => "plan_enrollment"}
    assert event["id"] == "team_sub_team"
    assert event["timestamp_ms"] == 1_800_000_000_000
    assert event["user"]["emails_sha256"] == [Analytics.hash_email("ada@example.com")]
  end

  test "disabled, missing, denied and expired consent never enqueue", %{account: account} do
    for attribution <- [nil, %{"marketing_allowed" => false},
        %{"marketing_allowed" => true, "captured_at" => 0}] do
      account = put_in(account.metadata.marketing_attribution, attribution)
      assert :ok = Analytics.registration_completed(account, %Portal.Actor{email: "ada@example.com"})
    end
    Portal.Config.put_env_override(:portal, OpenAI, api_key: nil)
    assert :ok = Analytics.registration_completed(account, %Portal.Actor{email: "ada@example.com"})
    assert [] == all_enqueued(worker: OpenAI)
  end

  test "delivery rechecks consent and skips an opted-out account", %{account: account} do
    Analytics.registration_completed(account, %Portal.Actor{email: "ada@example.com"})
    assert [job] = all_enqueued(worker: OpenAI)
    Analytics.update_marketing_attribution(account, %{"marketing_allowed" => false})
    assert :ok = OpenAI.perform(job)
  end

  test "normalizes email without Google's Gmail-specific dot removal" do
    assert Analytics.hash_email(" User.Name@GMAIL.COM ") ==
      :crypto.hash(:sha256, "user.name@gmail.com") |> Base.encode16(case: :lower)
    assert Analytics.hash_email("user.name@gmail.com") != Analytics.hash_email("username@gmail.com")
  end

  test "successful requests complete and invalid payloads are not retried" do
    Req.Test.expect(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 204, "") end)
    assert :ok = OpenAI.deliver(%{"id" => "success"})
    Req.Test.expect(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 400, "invalid") end)
    assert {:cancel, {:http_status, 400}} = OpenAI.deliver(%{"id" => "invalid"})
  end
end
