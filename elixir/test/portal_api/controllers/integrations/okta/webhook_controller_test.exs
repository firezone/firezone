defmodule PortalAPI.Integrations.Okta.WebhookControllerTest do
  use PortalAPI.ConnCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures
  import Portal.GroupFixtures
  import Portal.IdentityFixtures
  import Portal.ObanFixtures
  import Portal.OktaDirectoryFixtures

  alias Portal.Okta

  setup do
    account = account_fixture(features: %{idp_sync: true})
    directory = okta_directory_fixture(account: account)
    base_directory = Portal.Repo.get_by!(Portal.Directory, id: directory.id)
    %{account: account, directory: directory, base_directory: base_directory}
  end

  describe "verify/2" do
    test "echoes the verification challenge", %{conn: conn, directory: directory} do
      conn =
        conn
        |> put_req_header("x-okta-verification-challenge", "abc 123")
        |> put_req_header("authorization", directory.webhook_secret)
        |> get("/integrations/okta/webhooks?directory_id=#{directory.id}")

      assert json_response(conn, 200) == %{"verification" => "abc 123"}
    end

    test "refuses a verification without the hook secret", %{conn: conn, directory: directory} do
      conn =
        conn
        |> put_req_header("x-okta-verification-challenge", "abc 123")
        |> get("/integrations/okta/webhooks?directory_id=#{directory.id}")

      assert response(conn, 401)
      assert is_nil(Portal.Repo.get!(Portal.Okta.Directory, directory.id).webhook_verified_at)
    end

    test "refuses a verification with the wrong secret", %{conn: conn, directory: directory} do
      conn =
        conn
        |> put_req_header("x-okta-verification-challenge", "abc 123")
        |> put_req_header("authorization", "nope")
        |> get("/integrations/okta/webhooks?directory_id=#{directory.id}")

      assert response(conn, 401)
    end

    test "records the verification and tells the settings page",
         %{conn: conn, account: account, directory: directory} do
      :ok = Portal.PubSub.Changes.subscribe(account.id, :directories)

      conn =
        conn
        |> put_req_header("x-okta-verification-challenge", "abc")
        |> put_req_header("authorization", directory.webhook_secret)
        |> get("/integrations/okta/webhooks?directory_id=#{directory.id}")

      assert json_response(conn, 200)
      assert Portal.Repo.get!(Portal.Okta.Directory, directory.id).webhook_verified_at
      assert_receive :directories_changed
    end

    test "refuses a verification for an unknown directory like a wrong secret", %{conn: conn} do
      conn =
        conn
        |> put_req_header("x-okta-verification-challenge", "abc")
        |> put_req_header("authorization", "anything")
        |> get("/integrations/okta/webhooks?directory_id=#{Ecto.UUID.generate()}")

      assert response(conn, 401)
    end

    test "rejects a verification without a challenge", %{conn: conn, directory: directory} do
      conn = get(conn, "/integrations/okta/webhooks?directory_id=#{directory.id}")

      assert response(conn, 400)
    end
  end

  describe "handle_webhook/2" do
    test "queues one job per user and group the directory knows",
         %{conn: conn, account: account, directory: directory, base_directory: base_directory} do
      identity_fixture(
        account: account,
        directory: base_directory,
        issuer: Okta.Sync.issuer(directory),
        idp_id: "user-1"
      )

      group_fixture(account: account, directory: base_directory, idp_id: "group-1")

      conn =
        post_events(conn, directory, [
          event("user.account.update_profile", [user("user-1")]),
          event("user.lifecycle.deactivate", [user("user-1")]),
          event("group.profile.update", [group("group-1")]),
          event("user.account.update_profile", [user("user-unknown")]),
          event("group.profile.update", [group("group-unknown")])
        ])

      assert response(conn, 204) == ""

      jobs = all_enqueued(worker: Okta.WebhookSync)
      assert length(jobs) == 2
      assert_enqueued(worker: Okta.WebhookSync, args: %{resource: "user", resource_id: "user-1"})
      assert_enqueued(worker: Okta.WebhookSync, args: %{resource: "group", resource_id: "group-1"})
    end

    test "records when a delivery was last accepted", %{conn: conn, directory: directory} do
      assert is_nil(directory.webhook_received_at)

      conn = post_events(conn, directory, [event("user.account.update_profile", [user("user-1")])])

      assert response(conn, 204) == ""
      assert Portal.Repo.get!(Portal.Okta.Directory, directory.id).webhook_received_at
    end

    test "records nothing for a refused delivery", %{conn: conn, directory: directory} do
      conn =
        post_events(conn, directory, [event("user.account.update_profile", [user("user-1")])],
          secret: "nope"
        )

      assert response(conn, 401)
      assert is_nil(Portal.Repo.get!(Portal.Okta.Directory, directory.id).webhook_received_at)
    end

    test "queues an unknown user an event adds to the directory", %{conn: conn, directory: directory} do
      conn =
        post_events(conn, directory, [
          event("application.user_membership.add", [user("user-new")]),
          event("group.user_membership.add", [group("group-1"), user("user-joined")])
        ])

      assert response(conn, 204) == ""
      assert_enqueued(worker: Okta.WebhookSync, args: %{resource: "user", resource_id: "user-new"})
      assert_enqueued(worker: Okta.WebhookSync, args: %{resource: "user", resource_id: "user-joined"})
      assert length(all_enqueued(worker: Okta.WebhookSync)) == 2
    end

    test "queues an unknown group an application assignment adds", %{conn: conn, directory: directory} do
      conn =
        post_events(conn, directory, [
          event("group.application_assignment.add", [group("group-new"), app("app-1")])
        ])

      assert response(conn, 204) == ""
      assert_enqueued(worker: Okta.WebhookSync, args: %{resource: "group", resource_id: "group-new"})
    end

    test "queues a known group an application assignment removes",
         %{conn: conn, account: account, directory: directory, base_directory: base_directory} do
      group_fixture(account: account, directory: base_directory, idp_id: "group-1")

      conn =
        post_events(conn, directory, [
          event("group.application_assignment.remove", [group("group-1"), app("app-1")]),
          event("group.application_assignment.remove", [group("group-unknown"), app("app-1")])
        ])

      assert response(conn, 204) == ""
      assert_enqueued(worker: Okta.WebhookSync, args: %{resource: "group", resource_id: "group-1"})
      assert length(all_enqueued(worker: Okta.WebhookSync)) == 1
    end

    test "drops an unknown user for other events", %{conn: conn, directory: directory} do
      conn =
        post_events(conn, directory, [
          event("user.lifecycle.deactivate", [user("user-unknown")]),
          event("group.user_membership.remove", [group("group-1"), user("user-unknown")])
        ])

      assert response(conn, 204) == ""
      assert all_enqueued(worker: Okta.WebhookSync) == []
    end

    test "queues everything while a job for the directory is running", %{conn: conn, directory: directory} do
      executing_job(Okta.Sync.new(%{account_id: directory.account_id, directory_id: directory.id}))

      conn =
        post_events(conn, directory, [
          event("user.lifecycle.deactivate", [user("user-unknown")]),
          event("group.lifecycle.delete", [group("group-unknown")])
        ])

      assert response(conn, 204) == ""
      assert length(all_enqueued(worker: Okta.WebhookSync)) == 2
    end

    test "ignores targets whose ids are not Okta ids", %{conn: conn, directory: directory} do
      conn = post_events(conn, directory, [event("application.user_membership.add", [user("../etc")])])

      assert response(conn, 204) == ""
      assert all_enqueued(worker: Okta.WebhookSync) == []
    end

    test "refuses a delivery with the wrong secret", %{conn: conn, directory: directory} do
      conn =
        post_events(conn, directory, [event("application.user_membership.add", [user("user-1")])],
          secret: "nope"
        )

      assert response(conn, 401)
      assert all_enqueued(worker: Okta.WebhookSync) == []
    end

    test "refuses a delivery without an authorization header", %{conn: conn, directory: directory} do
      conn =
        post_events(conn, directory, [event("application.user_membership.add", [user("user-1")])],
          secret: nil
        )

      assert response(conn, 401)
    end

    test "refuses a delivery for an unknown directory like a wrong secret",
         %{conn: conn, directory: directory} do
      conn =
        post_events(
          conn,
          %{directory | id: Ecto.UUID.generate()},
          [event("application.user_membership.add", [user("user-1")])]
        )

      assert response(conn, 401)
    end

    test "rejects a body without events", %{conn: conn, directory: directory} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> put_req_header("authorization", directory.webhook_secret)
        |> post("/integrations/okta/webhooks?directory_id=#{directory.id}", JSON.encode!(%{"data" => %{}}))

      assert response(conn, 400)
    end

    test "rejects too many events", %{conn: conn, directory: directory} do
      events = for i <- 1..1001, do: event("user.account.update_profile", [user("user-#{i}")])
      conn = post_events(conn, directory, events)

      assert response(conn, 413)
    end
  end

  defp post_events(conn, directory, events, opts \\ []) do
    conn =
      case Keyword.get(opts, :secret, directory.webhook_secret) do
        nil -> conn
        secret -> put_req_header(conn, "authorization", secret)
      end

    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      "/integrations/okta/webhooks?directory_id=#{directory.id}",
      JSON.encode!(%{"eventType" => "com.okta.event_hook", "data" => %{"events" => events}})
    )
  end

  defp event(type, targets) do
    %{
      "eventType" => type,
      "uuid" => Ecto.UUID.generate(),
      "published" => "2026-09-07T00:00:00.000Z",
      "target" => targets
    }
  end

  defp user(id), do: %{"type" => "User", "id" => id, "alternateId" => "#{id}@example.com"}
  defp group(id), do: %{"type" => "UserGroup", "id" => id, "displayName" => id}
  defp app(id), do: %{"type" => "AppInstance", "id" => id, "displayName" => id}
end
