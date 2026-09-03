defmodule Portal.Google.SubscriptionsTest do
  use Portal.DataCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures
  import Portal.GoogleDirectoryFixtures
  import Portal.GoogleAPIClientHelpers

  alias Portal.Google.APIClient
  alias Portal.Google.Directory
  alias Portal.Google.Subscriptions

  setup do
    configure_google_api_client()
    account = account_fixture(features: %{idp_sync: true})
    %{account: account}
  end

  describe "perform/1 ensure" do
    test "opens a channel and stores what Google returned", %{account: account} do
      Portal.Config.put_env_override(:portal, :rest_api_url, "https://api.example.com/")
      directory = google_directory_fixture(account: account)
      stub_google()

      assert :ok = perform_job(Subscriptions, ensure_args(directory))

      directory = reload(directory)
      assert directory.webhook_secret
      assert directory.users_channel_id
      assert directory.users_resource_id == "resource-#{directory.users_channel_id}"
      assert_in_delta DateTime.diff(directory.channel_expires_at, DateTime.utc_now(), :minute), 360, 2

      expected_url =
        "https://api.example.com/integrations/google/webhooks?directory_id=#{directory.id}"

      assert Subscriptions.notification_url(directory.id) == expected_url

      assert_received {:google, "POST", "/admin/directory/v1/users/watch", body}
      assert body["id"] == directory.users_channel_id
      assert body["type"] == "web_hook"
      assert body["address"] == expected_url
      assert body["token"] == directory.webhook_secret
      assert is_integer(body["expiration"])

      refute_received {:google, "POST", "/admin/directory_v1/channels/stop", _body}

      assert_enqueued(
        worker: Subscriptions,
        args: %{account_id: directory.account_id, directory_id: directory.id, action: "renew"}
      )
    end

    test "does nothing while the channel is fresh", %{account: account} do
      directory = fresh_directory(account, 300)
      stub_google()

      assert :ok = perform_job(Subscriptions, ensure_args(directory))

      refute_received {:google, _method, _path, _body}
      assert reload(directory).users_channel_id == "existing-channel"

      assert_enqueued(
        worker: Subscriptions,
        args: %{directory_id: directory.id, action: "renew"}
      )
    end

    test "replaces a channel that expires soon and stops the old one", %{account: account} do
      directory = fresh_directory(account, 10)
      stub_google()

      assert :ok = perform_job(Subscriptions, ensure_args(directory))

      assert_received {:google, "POST", "/admin/directory/v1/users/watch", %{"token" => "secret"}}

      assert_received {:google, "POST", "/admin/directory_v1/channels/stop",
                       %{"id" => "existing-channel", "resourceId" => "existing-resource"}}

      directory = reload(directory)
      assert directory.webhook_secret == "secret"
      refute directory.users_channel_id == "existing-channel"
      assert DateTime.diff(directory.channel_expires_at, DateTime.utc_now(), :minute) >= 350
    end

    test "renew action behaves like ensure", %{account: account} do
      directory = fresh_directory(account, 10)
      stub_google()

      assert :ok = perform_job(Subscriptions, Map.put(ensure_args(directory), :action, "renew"))

      assert_received {:google, "POST", "/admin/directory/v1/users/watch", _body}
      refute reload(directory).users_channel_id == "existing-channel"
    end

    test "keeps the new channel when the old one cannot be stopped", %{account: account} do
      directory = fresh_directory(account, 10)
      stub_google(refuse_stop: ["existing-channel"])

      assert :ok = perform_job(Subscriptions, ensure_args(directory))

      directory = reload(directory)
      refute directory.users_channel_id == "existing-channel"
      assert directory.users_resource_id == "resource-#{directory.users_channel_id}"
    end

    test "snoozes when Google refuses the watch", %{account: account} do
      directory = google_directory_fixture(account: account)
      stub_google(refuse_watch: true)

      assert {:snooze, 600} = perform_job(Subscriptions, ensure_args(directory))

      directory = reload(directory)
      assert directory.webhook_secret
      assert is_nil(directory.users_channel_id)
      refute_enqueued(worker: Subscriptions)
    end

    test "skips disabled, unverified, and feature-less directories", %{account: account} do
      stub_google()

      disabled = google_directory_fixture(account: account, is_disabled: true)
      unverified = google_directory_fixture(account: account, is_verified: false)

      no_feature =
        google_directory_fixture(account: account_fixture(features: %{idp_sync: false}))

      for directory <- [disabled, unverified, no_feature] do
        assert :ok = perform_job(Subscriptions, ensure_args(directory))
        assert is_nil(reload(directory).users_channel_id)
      end

      refute_received {:google, _method, _path, _body}
      refute_enqueued(worker: Subscriptions)
    end
  end

  test "notification_url falls back to the API URL without a REST API URL" do
    assert Subscriptions.notification_url("dir") ==
             "http://localhost:13001/integrations/google/webhooks?directory_id=dir"
  end

  describe "perform/1 stop" do
    test "stops the channel and clears it from the directory", %{account: account} do
      directory = fresh_directory(account, 300)
      stub_google()

      assert :ok = perform_job(Subscriptions, stop_args(directory))

      assert_received {:google, "POST", "/admin/directory_v1/channels/stop",
                       %{"id" => "existing-channel", "resourceId" => "existing-resource"}}

      directory = reload(directory)
      assert is_nil(directory.users_channel_id)
      assert is_nil(directory.users_resource_id)
      assert is_nil(directory.channel_expires_at)
    end

    test "leaves a newer channel alone", %{account: account} do
      directory = fresh_directory(account, 300)
      stub_google()

      args = %{stop_args(directory) | channel_id: "old-channel", resource_id: "old-resource"}
      assert :ok = perform_job(Subscriptions, args)

      assert reload(directory).users_channel_id == "existing-channel"
    end

    test "stops the channel as the admin it was opened with", %{account: account} do
      directory = fresh_directory(account, 300)
      stub_google()
      args = %{stop_args(directory) | impersonation_email: "old-admin@example.com"}

      directory
      |> Ecto.Changeset.change(impersonation_email: "new-admin@example.com")
      |> Repo.update!()

      assert :ok = perform_job(Subscriptions, args)

      assert_received {:google, "POST", "/token", %{"sub" => "old-admin@example.com"}}
      assert is_nil(reload(directory).users_channel_id)
    end

    test "works after the directory row is gone", %{account: account} do
      directory = fresh_directory(account, 300)
      stub_google()
      args = stop_args(directory)
      Repo.delete!(directory)

      assert :ok = perform_job(Subscriptions, args)

      assert_received {:google, "POST", "/admin/directory_v1/channels/stop", _body}
    end

    test "returns an error when Google refuses so Oban retries", %{account: account} do
      directory = fresh_directory(account, 300)
      stub_google(refuse_stop: ["existing-channel"])

      assert {:error, {:stop_channel, _response}} = perform_job(Subscriptions, stop_args(directory))

      assert reload(directory).users_channel_id == "existing-channel"
    end
  end

  defp stop_args(directory) do
    %{
      action: "stop",
      account_id: directory.account_id,
      directory_id: directory.id,
      impersonation_email: directory.impersonation_email,
      channel_id: directory.users_channel_id,
      resource_id: directory.users_resource_id
    }
  end

  defp ensure_args(directory) do
    %{account_id: directory.account_id, directory_id: directory.id, action: "ensure"}
  end

  defp fresh_directory(account, minutes_left) do
    google_directory_fixture(
      account: account,
      webhook_secret: "secret",
      users_channel_id: "existing-channel",
      users_resource_id: "existing-resource",
      channel_expires_at: DateTime.add(DateTime.utc_now(), minutes_left, :minute)
    )
  end

  defp reload(directory) do
    Repo.get_by!(Directory, id: directory.id)
  end

  defp jwt_claims(body) do
    %{"assertion" => jwt} = URI.decode_query(body)
    [_header, payload, _signature] = String.split(jwt, ".")
    payload |> Base.url_decode64!(padding: false) |> JSON.decode!()
  end

  defp stub_google(opts \\ []) do
    refuse_watch = Keyword.get(opts, :refuse_watch, false)
    refuse_stop = Keyword.get(opts, :refuse_stop, [])
    test_pid = self()

    Req.Test.stub(APIClient, fn conn ->
      path = conn.request_path

      cond do
        path == "/token" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          send(test_pid, {:google, "POST", path, jwt_claims(body)})
          Req.Test.json(conn, %{"access_token" => "token", "expires_in" => 3600})

        conn.method == "POST" and path == "/admin/directory/v1/users/watch" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          body = JSON.decode!(body)
          send(test_pid, {:google, "POST", path, body})

          if refuse_watch do
            conn |> Plug.Conn.put_status(403) |> Req.Test.json(%{"error" => "forbidden"})
          else
            Req.Test.json(conn, %{
              "kind" => "api#channel",
              "id" => body["id"],
              "resourceId" => "resource-#{body["id"]}",
              "expiration" => Integer.to_string(body["expiration"])
            })
          end

        conn.method == "POST" and path == "/admin/directory_v1/channels/stop" ->
          {:ok, body, conn} = Plug.Conn.read_body(conn)
          body = JSON.decode!(body)
          send(test_pid, {:google, "POST", path, body})

          if body["id"] in refuse_stop do
            conn |> Plug.Conn.put_status(429) |> Req.Test.json(%{"error" => "throttled"})
          else
            Plug.Conn.send_resp(conn, 204, "")
          end

        true ->
          send(test_pid, {:google, conn.method, path, nil})
          Req.Test.json(conn, %{"error" => "unexpected: #{path}"})
      end
    end)
  end
end
