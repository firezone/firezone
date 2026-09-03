defmodule Portal.Entra.SubscriptionsTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures
  import Portal.EntraDirectoryFixtures

  alias Portal.Entra.Directory
  alias Portal.Entra.Subscriptions
  alias Portal.Microsoft.Graph.APIClient

  setup do
    account = account_fixture(features: %{idp_sync: true})
    %{account: account}
  end

  describe "perform/1 ensure" do
    test "creates both subscriptions and stores their ids", %{account: account} do
      Portal.Config.put_env_override(:portal, :rest_api_url, "https://api.example.com/")
      directory = entra_directory_fixture(account: account)
      stub_graph()

      assert :ok = perform_job(Subscriptions, ensure_args(directory))

      directory = reload(directory)
      assert directory.webhook_secret
      assert directory.users_subscription_id == "sub-/users"
      assert directory.groups_subscription_id == "sub-/groups"
      assert_in_delta DateTime.diff(directory.subscriptions_expire_at, DateTime.utc_now(), :day), 28, 1

      expected_url =
        "https://api.example.com/integrations/entra/webhooks?directory_id=#{directory.id}"

      assert Subscriptions.notification_url(directory.id) == expected_url

      assert_received {:graph, "POST", "/v1.0/subscriptions", body}
      assert body["resource"] in ["/users", "/groups"]
      assert body["changeType"] == "updated,deleted"
      assert body["notificationUrl"] == expected_url
      assert body["lifecycleNotificationUrl"] == expected_url
      assert body["clientState"] == directory.webhook_secret
      assert {:ok, _, _} = DateTime.from_iso8601(body["expirationDateTime"])

      assert_received {:graph, "POST", "/v1.0/subscriptions", _body}
    end

    test "does nothing while the subscriptions are fresh", %{account: account} do
      directory = fresh_directory(account, 20)
      stub_graph()

      assert :ok = perform_job(Subscriptions, ensure_args(directory))

      refute_received {:graph, _method, _path, _body}
      assert reload(directory).users_subscription_id == "existing-users"
    end

    test "renews subscriptions that expire soon", %{account: account} do
      directory = fresh_directory(account, 2)
      stub_graph()

      assert :ok = perform_job(Subscriptions, ensure_args(directory))

      assert_received {:graph, "PATCH", "/v1.0/subscriptions/existing-users", body}
      assert {:ok, _, _} = DateTime.from_iso8601(body["expirationDateTime"])
      assert_received {:graph, "PATCH", "/v1.0/subscriptions/existing-groups", _body}

      directory = reload(directory)
      assert directory.users_subscription_id == "existing-users"
      assert directory.groups_subscription_id == "existing-groups"
      assert DateTime.diff(directory.subscriptions_expire_at, DateTime.utc_now(), :day) >= 27
    end

    test "recreates a subscription Graph no longer knows", %{account: account} do
      directory = fresh_directory(account, 2)
      stub_graph(missing: ["existing-users"])

      assert :ok = perform_job(Subscriptions, ensure_args(directory))

      directory = reload(directory)
      assert directory.users_subscription_id == "sub-/users"
      assert directory.groups_subscription_id == "existing-groups"
    end

    test "renew action renews even when fresh", %{account: account} do
      directory = fresh_directory(account, 20)
      stub_graph()

      assert :ok = perform_job(Subscriptions, Map.put(ensure_args(directory), :action, "renew"))

      assert_received {:graph, "PATCH", "/v1.0/subscriptions/existing-users", _body}
      assert_received {:graph, "PATCH", "/v1.0/subscriptions/existing-groups", _body}
    end

    test "recreate action replaces only the removed subscription", %{account: account} do
      directory = fresh_directory(account, 20)
      stub_graph()

      args =
        directory
        |> ensure_args()
        |> Map.merge(%{action: "recreate", subscription_id: "existing-groups"})

      assert :ok = perform_job(Subscriptions, args)

      assert_received {:graph, "PATCH", "/v1.0/subscriptions/existing-users", _body}
      assert_received {:graph, "POST", "/v1.0/subscriptions", %{"resource" => "/groups"}}

      directory = reload(directory)
      assert directory.users_subscription_id == "existing-users"
      assert directory.groups_subscription_id == "sub-/groups"
    end

    test "returns an error when Graph refuses the subscription", %{account: account} do
      directory = entra_directory_fixture(account: account)

      Req.Test.stub(APIClient, fn conn ->
        if String.ends_with?(conn.request_path, "/oauth2/v2.0/token") do
          Req.Test.json(conn, %{"access_token" => "token"})
        else
          conn
          |> Plug.Conn.put_status(403)
          |> Req.Test.json(%{"error" => %{"message" => "forbidden"}})
        end
      end)

      assert {:error, {:create_subscription, :users, _response}} =
               perform_job(Subscriptions, ensure_args(directory))

      directory = reload(directory)
      assert directory.webhook_secret
      assert is_nil(directory.users_subscription_id)
    end

    test "skips disabled, unverified, and feature-less directories", %{account: account} do
      stub_graph()

      disabled = entra_directory_fixture(account: account, is_disabled: true)
      unverified = entra_directory_fixture(account: account, is_verified: false)
      no_feature = entra_directory_fixture(account: account_fixture(features: %{idp_sync: false}))

      for directory <- [disabled, unverified, no_feature] do
        assert :ok = perform_job(Subscriptions, ensure_args(directory))
        assert is_nil(reload(directory).users_subscription_id)
      end

      refute_received {:graph, _method, _path, _body}
    end
  end

  test "notification_url falls back to the API URL without a REST API URL" do
    assert Subscriptions.notification_url("dir") ==
             "http://localhost:13001/integrations/entra/webhooks?directory_id=dir"
  end

  describe "perform/1 delete" do
    test "deletes the given subscriptions", %{account: _account} do
      stub_graph()

      assert :ok =
               perform_job(Subscriptions, %{
                 action: "delete",
                 tenant_id: "tenant",
                 subscription_ids: ["a", "b"]
               })

      assert_received {:graph, "DELETE", "/v1.0/subscriptions/a", _body}
      assert_received {:graph, "DELETE", "/v1.0/subscriptions/b", _body}
    end
  end

  defp ensure_args(directory) do
    %{account_id: directory.account_id, directory_id: directory.id, action: "ensure"}
  end

  defp fresh_directory(account, days_left) do
    entra_directory_fixture(
      account: account,
      webhook_secret: "secret",
      users_subscription_id: "existing-users",
      groups_subscription_id: "existing-groups",
      subscriptions_expire_at: DateTime.add(DateTime.utc_now(), days_left, :day)
    )
  end

  defp reload(directory) do
    Repo.get_by!(Directory, id: directory.id)
  end

  defp stub_graph(opts \\ []) do
    missing = Keyword.get(opts, :missing, [])
    test_pid = self()

    Req.Test.stub(APIClient, fn conn ->
      path = conn.request_path

      cond do
        String.ends_with?(path, "/oauth2/v2.0/token") ->
          Req.Test.json(conn, %{"access_token" => "token"})

        conn.method == "POST" and path == "/v1.0/subscriptions" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          body = JSON.decode!(body)
          send(test_pid, {:graph, "POST", path, body})

          conn
          |> Plug.Conn.put_status(201)
          |> Req.Test.json(Map.put(body, "id", "sub-#{body["resource"]}"))

        conn.method == "PATCH" and String.starts_with?(path, "/v1.0/subscriptions/") ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          body = JSON.decode!(body)
          send(test_pid, {:graph, "PATCH", path, body})

          if Path.basename(path) in missing do
            conn |> Plug.Conn.put_status(404) |> Req.Test.json(%{"error" => "gone"})
          else
            Req.Test.json(conn, Map.put(body, "id", Path.basename(path)))
          end

        conn.method == "DELETE" and String.starts_with?(path, "/v1.0/subscriptions/") ->
          send(test_pid, {:graph, "DELETE", path, nil})
          Plug.Conn.send_resp(conn, 204, "")

        true ->
          send(test_pid, {:graph, conn.method, path, nil})
          Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
      end
    end)
  end
end
