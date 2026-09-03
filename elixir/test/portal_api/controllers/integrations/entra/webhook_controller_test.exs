defmodule PortalAPI.Integrations.Entra.WebhookControllerTest do
  use PortalAPI.ConnCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Portal.AccountFixtures
  import Portal.EntraDirectoryFixtures
  import Portal.GroupFixtures
  import Portal.IdentityFixtures

  alias Portal.Entra

  @secret "webhook-secret"

  setup do
    account = account_fixture(features: %{idp_sync: true})

    directory =
      entra_directory_fixture(
        account: account,
        webhook_secret: @secret,
        users_subscription_id: "sub-users",
        groups_subscription_id: "sub-groups"
      )

    %{account: account, directory: directory}
  end

  describe "handle_webhook/2" do
    test "echoes the validation token as plain text", %{conn: conn, directory: directory} do
      conn =
        post(conn, "/integrations/entra/webhooks?directory_id=#{directory.id}&validationToken=abc%20123")

      assert response(conn, 200) == "abc 123"
      assert response_content_type(conn, :text) =~ "text/plain"
    end

    test "queues one job per changed resource this directory knows", %{
      conn: conn,
      account: account,
      directory: directory
    } do
      base_directory = Portal.Repo.get_by!(Portal.Directory, id: directory.id)
      issuer = Entra.Sync.issuer(directory)

      for id <- ["user-1", "user-2"] do
        identity_fixture(account: account, directory: base_directory, issuer: issuer, idp_id: id)
      end

      group_fixture(account: account, directory: base_directory, idp_id: "group-1")

      conn =
        post_notifications(conn, directory, [
          change("Users", "user-1", "updated"),
          change("Users", "user-1", "updated"),
          change("Groups", "group-1", "updated"),
          change("Users", "user-2", "deleted"),
          change("Users", "user-unknown", "updated"),
          change("Groups", "group-unknown", "updated")
        ])

      assert response(conn, 202) == ""

      jobs = all_enqueued(worker: Entra.WebhookSync)
      assert length(jobs) == 3

      assert_enqueued(
        worker: Entra.WebhookSync,
        args: %{
          account_id: directory.account_id,
          directory_id: directory.id,
          resource: "user",
          resource_id: "user-1",
          change_type: "updated"
        }
      )

      assert_enqueued(
        worker: Entra.WebhookSync,
        args: %{resource: "group", resource_id: "group-1", change_type: "updated"}
      )

      assert_enqueued(
        worker: Entra.WebhookSync,
        args: %{resource: "user", resource_id: "user-2", change_type: "deleted"}
      )
    end

    test "queues unknown groups when the directory syncs all groups", %{
      conn: conn,
      account: account
    } do
      directory =
        entra_directory_fixture(account: account, webhook_secret: @secret, sync_all_groups: true)

      conn =
        post_notifications(conn, directory, [
          change("Groups", "group-new", "updated"),
          change("Users", "user-unknown", "updated")
        ])

      assert response(conn, 202) == ""

      assert [job] = all_enqueued(worker: Entra.WebhookSync)
      assert job.args["resource_id"] == "group-new"
    end

    test "queues subscription maintenance for lifecycle events", %{
      conn: conn,
      directory: directory
    } do
      conn =
        post_notifications(conn, directory, [
          lifecycle("reauthorizationRequired", "sub-users"),
          lifecycle("subscriptionRemoved", "sub-groups"),
          lifecycle("missed", "sub-users")
        ])

      assert response(conn, 202) == ""

      assert_enqueued(
        worker: Entra.Subscriptions,
        args: %{account_id: directory.account_id, directory_id: directory.id, action: "renew"}
      )

      assert_enqueued(
        worker: Entra.Subscriptions,
        args: %{directory_id: directory.id, action: "recreate", subscription_id: "sub-groups"}
      )

      assert_enqueued(
        worker: Entra.Sync,
        args: %{account_id: directory.account_id, directory_id: directory.id}
      )
    end

    test "drops notifications with the wrong clientState", %{conn: conn, directory: directory} do
      notification = change("Users", "user-1", "updated") |> Map.put("clientState", "nope")

      conn = post_notifications(conn, directory, [notification])

      assert response(conn, 202) == ""
      assert all_enqueued() == []
    end

    test "drops notifications without a clientState", %{conn: conn, directory: directory} do
      notification = change("Users", "user-1", "updated") |> Map.delete("clientState")

      conn = post_notifications(conn, directory, [notification])

      assert response(conn, 202) == ""
      assert all_enqueued() == []
    end

    test "drops notifications for an unknown directory", %{conn: conn, directory: directory} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(
          "/integrations/entra/webhooks?directory_id=#{Ecto.UUID.generate()}",
          JSON.encode!(%{"value" => [change("Users", "user-1", "updated")]})
        )

      assert response(conn, 202) == ""
      assert all_enqueued() == []

      conn =
        build_conn()
        |> put_req_header("content-type", "application/json")
        |> post(
          "/integrations/entra/webhooks?directory_id=not-a-uuid",
          JSON.encode!(%{"value" => [change("Users", "user-1", "updated")]})
        )

      assert response(conn, 202) == ""
      assert all_enqueued() == []
      assert directory.id
    end

    test "drops notifications for a disabled directory", %{conn: conn, account: account} do
      directory =
        entra_directory_fixture(account: account, webhook_secret: @secret, is_disabled: true)

      conn = post_notifications(conn, directory, [change("Users", "user-1", "updated")])

      assert response(conn, 202) == ""
      assert all_enqueued() == []
    end

    test "ignores unsupported resources", %{conn: conn, directory: directory} do
      notification =
        change("Users", "user-1", "updated")
        |> put_in(["resourceData", "@odata.type"], "#Microsoft.Graph.Device")

      conn = post_notifications(conn, directory, [notification])

      assert response(conn, 202) == ""
      assert all_enqueued() == []
    end

    test "rejects invalid JSON", %{conn: conn, directory: directory} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post("/integrations/entra/webhooks?directory_id=#{directory.id}", "{not json")

      assert response(conn, 400) =~ "invalid JSON"
    end

    test "rejects a body without notifications", %{conn: conn, directory: directory} do
      conn =
        conn
        |> put_req_header("content-type", "application/json")
        |> post(
          "/integrations/entra/webhooks?directory_id=#{directory.id}",
          JSON.encode!(%{"value" => "nope"})
        )

      assert response(conn, 400) =~ "missing notifications"
    end
  end

  defp post_notifications(conn, directory, notifications) do
    conn
    |> put_req_header("content-type", "application/json")
    |> post(
      "/integrations/entra/webhooks?directory_id=#{directory.id}",
      JSON.encode!(%{"value" => notifications})
    )
  end

  defp change(kind, id, change_type) do
    type = if kind == "Users", do: "#Microsoft.Graph.User", else: "#Microsoft.Graph.Group"

    %{
      "subscriptionId" => "sub-#{String.downcase(kind)}",
      "subscriptionExpirationDateTime" => "2026-09-30T00:00:00.0000000Z",
      "clientState" => @secret,
      "changeType" => change_type,
      "resource" => "#{kind}/#{id}",
      "tenantId" => "tenant",
      "resourceData" => %{
        "@odata.type" => type,
        "@odata.id" => "#{kind}/#{id}",
        "id" => id
      }
    }
  end

  defp lifecycle(event, subscription_id) do
    %{
      "subscriptionId" => subscription_id,
      "subscriptionExpirationDateTime" => "2026-09-30T00:00:00.0000000Z",
      "clientState" => @secret,
      "tenantId" => "tenant",
      "lifecycleEvent" => event
    }
  end
end
