defmodule PortalAPI.Integrations.Google.WebhookControllerTest do
  use PortalAPI.ConnCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures
  import Portal.GoogleDirectoryFixtures
  import Portal.IdentityFixtures

  alias Portal.Google

  @secret "webhook-secret"

  setup do
    account = account_fixture(features: %{idp_sync: true})

    directory =
      google_directory_fixture(
        account: account,
        orgunit_sync_enabled: false,
        webhook_secret: @secret,
        users_channel_id: "channel-1",
        users_resource_id: "resource-1"
      )

    %{account: account, directory: directory}
  end

  describe "handle_webhook/2" do
    test "accepts the sync message without queueing", %{conn: conn, directory: directory} do
      conn = post_notification(conn, directory, "sync", "")

      assert response(conn, 200) == ""
      assert all_enqueued() == []
    end

    test "queues one job per user this directory knows", %{
      conn: conn,
      account: account,
      directory: directory
    } do
      base_directory = Portal.Repo.get_by!(Portal.Directory, id: directory.id)

      for id <- ["user-1", "user-2"] do
        identity_fixture(
          account: account,
          directory: base_directory,
          issuer: Google.Sync.issuer(),
          idp_id: id
        )
      end

      for {state, id} <- [
            {"update", "user-1"},
            {"update", "user-1"},
            {"delete", "user-2"},
            {"add", "user-unknown"}
          ] do
        conn = post_notification(conn, directory, state, user(id))
        assert response(conn, 200) == ""
      end

      jobs = all_enqueued(worker: Google.WebhookSync)
      assert length(jobs) == 2

      assert_enqueued(
        worker: Google.WebhookSync,
        args: %{account_id: directory.account_id, directory_id: directory.id, user_id: "user-1"}
      )

      assert_enqueued(worker: Google.WebhookSync, args: %{user_id: "user-2"})
    end

    test "queues unknown users when org unit sync is on", %{conn: conn, account: account} do
      directory =
        google_directory_fixture(
          account: account,
          orgunit_sync_enabled: true,
          webhook_secret: @secret
        )

      conn = post_notification(conn, directory, "add", user("user-new"))

      assert response(conn, 200) == ""
      assert [job] = all_enqueued(worker: Google.WebhookSync)
      assert job.args["user_id"] == "user-new"
    end

    test "drops notifications with the wrong token", %{conn: conn, directory: directory} do
      conn = post_notification(conn, directory, "update", user("user-1"), token: "nope")

      assert response(conn, 200) == ""
      assert all_enqueued() == []
    end

    test "drops notifications without a token", %{conn: conn, directory: directory} do
      conn = post_notification(conn, directory, "update", user("user-1"), token: nil)

      assert response(conn, 200) == ""
      assert all_enqueued() == []
    end

    test "drops notifications for an unknown directory", %{conn: conn, directory: directory} do
      for directory_id <- [Ecto.UUID.generate(), "not-a-uuid"] do
        conn =
          conn
          |> put_headers(@secret, "update")
          |> post("/integrations/google/webhooks?directory_id=#{directory_id}", user("user-1"))

        assert response(conn, 200) == ""
      end

      assert all_enqueued() == []
      assert directory.id
    end

    test "drops notifications for a disabled directory", %{conn: conn, account: account} do
      directory =
        google_directory_fixture(
          account: account,
          orgunit_sync_enabled: true,
          webhook_secret: @secret,
          is_disabled: true
        )

      conn = post_notification(conn, directory, "update", user("user-1"))

      assert response(conn, 200) == ""
      assert all_enqueued() == []
    end

    test "drops notifications when the account lacks directory sync", %{conn: conn} do
      account = account_fixture(features: %{idp_sync: false})

      directory =
        google_directory_fixture(
          account: account,
          orgunit_sync_enabled: true,
          webhook_secret: @secret
        )

      conn = post_notification(conn, directory, "update", user("user-1"))

      assert response(conn, 200) == ""
      assert all_enqueued() == []
    end

    test "ignores a body without a user id", %{conn: conn, account: account} do
      directory =
        google_directory_fixture(
          account: account,
          orgunit_sync_enabled: true,
          webhook_secret: @secret
        )

      for body <- ["{not json", JSON.encode!(%{"kind" => "admin#directory#user"}), ""] do
        conn = post_notification(conn, directory, "update", body)
        assert response(conn, 200) == ""
      end

      assert all_enqueued() == []
    end

    test "rejects oversized bodies", %{conn: conn, directory: directory} do
      body = JSON.encode!(%{"id" => "user-1", "padding" => String.duplicate("x", 1_000_001)})

      conn = post_notification(conn, directory, "update", body)

      assert response(conn, 413) =~ "Too Large"
      assert all_enqueued() == []
    end
  end

  defp post_notification(conn, directory, state, body, opts \\ []) do
    token = Keyword.get(opts, :token, @secret)

    conn
    |> put_headers(token, state)
    |> post("/integrations/google/webhooks?directory_id=#{directory.id}", body)
  end

  defp put_headers(conn, token, state) do
    conn =
      conn
      |> put_req_header("content-type", "application/json")
      |> put_req_header("x-goog-channel-id", "channel-1")
      |> put_req_header("x-goog-resource-id", "resource-1")
      |> put_req_header("x-goog-resource-state", state)
      |> put_req_header("x-goog-message-number", "1")

    if token do
      put_req_header(conn, "x-goog-channel-token", token)
    else
      conn
    end
  end

  defp user(id) do
    JSON.encode!(%{
      "kind" => "admin#directory#user",
      "id" => id,
      "etag" => "etag",
      "primaryEmail" => "#{id}@example.com"
    })
  end
end
