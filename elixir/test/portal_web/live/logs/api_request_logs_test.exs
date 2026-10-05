defmodule PortalWeb.Logs.APIRequestLogsTest do
  use PortalWeb.ConnCase, async: true

  import Phoenix.LiveViewTest, except: [live: 2]

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.APIRequestLogFixtures

  # The table loads in an async task, so wait for it before returning.
  defp live(conn, path) do
    case Phoenix.LiveViewTest.live(conn, path) do
      {:ok, lv, _html} -> {:ok, lv, render_async(lv)}
      other -> other
    end
  end

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)
    %{account: account, actor: actor}
  end

  describe "index" do
    test "truncates the path and shows the full path on hover", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      path = "/resources?limit=25&filter[name]=" <> String.duplicate("a", 200)
      log = api_request_log_fixture(account: account, path: path)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/logs/api_request_logs")

      selector = "#api-request-log-#{log.log_id} span.truncate[title='#{path}']"

      assert has_element?(lv, selector)
      refute has_element?(lv, "#api-request-log-#{log.log_id} .break-all")
    end
  end
end
