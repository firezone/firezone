defmodule PortalWeb.AnalyticsTest do
  use PortalWeb.ConnCase, async: true

  import ExUnit.CaptureLog
  import Portal.AccountFixtures
  import Portal.ActorFixtures

  alias Portal.Analytics.PostHog

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)
    test_pid = self()

    Req.Test.stub(__MODULE__, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(test_pid, {:posthog, JSON.decode!(body)})
      Req.Test.json(conn, %{"status" => "Ok"})
    end)

    put_posthog_config(enabled: true)

    %{account: account, actor: actor}
  end

  describe "page views" do
    test "sends a page view with the route pattern", %{conn: conn, account: account, actor: actor} do
      {:ok, _lv, _html} = conn |> authorize_conn(actor) |> live(~p"/#{account}/sites")

      assert_receive {:posthog, %{"event" => "$pageview", "properties" => properties} = body}

      assert properties["distinct_id"] == actor.id
      assert properties["$groups"] == %{"account" => account.id}
      refute Map.has_key?(properties, "$process_person_profile")
      assert properties["account_name"] == account.name
      assert properties["account_slug"] == account.slug
      assert properties["$pathname"] == "/:account_id_or_slug/sites"
      assert properties["$current_url"] == PortalWeb.Endpoint.url() <> "/:account_id_or_slug/sites"
      assert properties["view"] == "PortalWeb.Sites"
      refute JSON.encode!(body) =~ actor.email
    end

    test "sends one page view per route, not per patch", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} = conn |> authorize_conn(actor) |> live(~p"/#{account}/sites")
      assert_receive {:posthog, %{"event" => "$pageview"}}

      render_patch(lv, ~p"/#{account}/sites?#{%{"sites_order_by" => "sites:asc:name"}}")
      refute_receive {:posthog, %{"event" => "$pageview"}}, 200

      render_patch(lv, ~p"/#{account}/sites/new")

      assert_receive {:posthog,
                      %{
                        "event" => "$pageview",
                        "properties" => %{
                          "$pathname" => "/:account_id_or_slug/sites/new",
                          "live_action" => "new"
                        }
                      }}
    end

    test "sends nothing for visitors who are not signed in", %{conn: conn, account: account} do
      {:ok, _lv, _html} = live(conn, ~p"/#{account}/sign_in")

      refute_receive {:posthog, _body}, 200
    end
  end

  describe "actions" do
    test "sends the event name without its params", %{conn: conn, account: account, actor: actor} do
      {:ok, lv, _html} = conn |> authorize_conn(actor) |> live(~p"/#{account}/sites")
      assert_receive {:posthog, %{"event" => "$pageview"}}

      render_click(lv, "dismiss_rotated_gateway_token", %{"secret" => "do-not-send"})

      assert_receive {:posthog, %{"event" => "Portal Action", "properties" => properties} = body}

      assert properties["action"] == "dismiss_rotated_gateway_token"
      assert properties["view"] == "PortalWeb.Sites"
      assert properties["$pathname"] == "/:account_id_or_slug/sites"
      assert properties["$groups"] == %{"account" => account.id}
      assert properties["account_name"] == account.name
      assert properties["account_slug"] == account.slug
      assert properties["distinct_id"] == actor.id
      refute JSON.encode!(body) =~ "do-not-send"
    end

    test "attributes LiveComponent events to the page's actor and account", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      actor =
        actor
        |> Ecto.Changeset.change()
        |> Ecto.Changeset.put_embed(:preferences, %Portal.Actor.Preferences{getting_started: :pending})
        |> Portal.Repo.update!()

      {:ok, lv, _html} = conn |> authorize_conn(actor) |> live(~p"/#{account}/sites")
      assert_receive {:posthog, %{"event" => "$pageview"}}

      lv |> element("#getting-started-goal-device_mesh") |> render_click()

      assert_receive {:posthog, %{"event" => "Portal Action", "properties" => properties}}

      assert properties["action"] == "choose"
      assert properties["component"] == "PortalWeb.GettingStarted"
      assert properties["view"] == "PortalWeb.Sites"
      assert properties["distinct_id"] == actor.id
      assert properties["$groups"] == %{"account" => account.id}
    end

    test "skips UI chrome such as opening and closing panels", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} = conn |> authorize_conn(actor) |> live(~p"/#{account}/sites")
      assert_receive {:posthog, %{"event" => "$pageview"}}

      render_click(lv, "open_new_site_panel", %{})
      render_click(lv, "close_new_site_panel", %{})

      refute_receive {:posthog, %{"event" => "Portal Action"}}, 200
    end

    test "skips form change and keydown events", %{conn: conn, account: account, actor: actor} do
      {:ok, lv, _html} = conn |> authorize_conn(actor) |> live(~p"/#{account}/sites")
      assert_receive {:posthog, %{"event" => "$pageview"}}

      render_change(lv, "new_site_change", %{"_target" => ["site", "name"], "site" => %{"name" => "x"}})
      render_keydown(lv, "handle_keydown", %{"key" => "Escape"})

      refute_receive {:posthog, %{"event" => "Portal Action"}}, 200
    end
  end

  test "sends nothing when PostHog is disabled", %{conn: conn, account: account, actor: actor} do
    put_posthog_config(enabled: false)

    {:ok, lv, _html} = conn |> authorize_conn(actor) |> live(~p"/#{account}/sites")
    render_click(lv, "open_new_site_panel", %{})

    refute_receive {:posthog, _body}, 200
  end

  test "logs instead of raising out of the telemetry handler, which would detach it" do
    log =
      capture_log(fn ->
        assert :ok =
                 PortalWeb.Analytics.handle_event(
                   [:phoenix, :live_view, :handle_params, :stop],
                   %{},
                   %{socket: :not_a_socket, uri: "not a uri"},
                   nil
                 )
      end)

    assert log =~ "Portal analytics event failed"
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
