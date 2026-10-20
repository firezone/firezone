defmodule Portal.Workers.ProductAnalyticsSnapshotTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures

  alias Portal.Analytics.PostHog
  alias Portal.Workers.ProductAnalyticsSnapshot

  test "sends account snapshots to the PostHog batch endpoint" do
    account = account_fixture()
    put_posthog_config(enabled: true)
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:posthog_request, conn.request_path, JSON.decode!(body)})
      Req.Test.json(conn, %{"status" => "Ok"})
    end)

    assert :ok = perform_job(ProductAnalyticsSnapshot, %{})

    assert_receive {:posthog_request, "/batch/", %{"api_key" => "phc_test", "batch" => events}}

    assert Enum.any?(events, fn event ->
             event["event"] == "$groupidentify" and
               event["properties"]["$group_key"] == account.id
           end)
  end

  test "returns an error so Oban retries when PostHog rejects the batch" do
    account_fixture()
    put_posthog_config(enabled: true)

    Req.Test.stub(__MODULE__, fn conn -> Plug.Conn.send_resp(conn, 503, "") end)

    assert {:error, {:http_status, 503}} = perform_job(ProductAnalyticsSnapshot, %{})
  end

  test "does nothing when PostHog is disabled" do
    account_fixture()
    put_posthog_config(enabled: false)

    Req.Test.stub(__MODULE__, fn _conn -> flunk("unexpected PostHog request") end)

    assert :ok = perform_job(ProductAnalyticsSnapshot, %{})
  end

  defp put_posthog_config(opts) do
    Portal.Config.put_env_override(
      :portal,
      PostHog,
      Keyword.merge(
        [
          host: "https://posthog.test",
          project_api_key: "phc_test",
          req_opts: [retry: false, plug: {Req.Test, __MODULE__}]
        ],
        opts
      )
    )
  end
end
