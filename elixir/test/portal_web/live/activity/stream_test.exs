defmodule PortalWeb.Activity.StreamTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.APIRequestLogFixtures
  import Portal.ChangeLogFixtures
  import Portal.FlowLogFixtures
  import Portal.GroupFixtures
  import Portal.SessionLogFixtures

  setup do
    account = account_fixture()
    admin = admin_actor_fixture(account: account, name: "Jamie Admin")
    person = actor_fixture(account: account, name: "Lee Chen")

    %{account: account, admin: admin, person: person}
  end

  defp ago(seconds), do: DateTime.add(DateTime.utc_now(), -seconds, :second)

  defp subject_for(actor) do
    %{"actor_id" => actor.id, "actor_name" => actor.name, "actor_email" => actor.email}
  end

  test "redirects to sign in when not authenticated", %{conn: conn, account: account} do
    path = ~p"/#{account}/activity"
    assert {:error, {:redirect, %{to: to}}} = live(conn, path)
    assert to =~ "sign_in"
  end

  test "merges every log type newest first", %{conn: conn, account: account, admin: admin, person: person} do
    group = group_fixture(account: account, name: "On-call")

    change =
      change_log_fixture(
        account: account,
        timestamp: ago(10),
        object: "memberships",
        operation: :delete,
        before: %{"id" => Ecto.UUID.generate(), "actor_id" => person.id, "group_id" => group.id},
        after: nil,
        subject: subject_for(admin)
      )

    session =
      session_log_fixture(
        account: account,
        timestamp: ago(40),
        subject: subject_for(person) |> Map.put("device_id", Ecto.UUID.generate())
      )

    flow =
      flow_log_fixture(
        account: account,
        flow_start: ago(20),
        initiator_actor_id: person.id,
        initiator_actor_name: person.name,
        resource_name: "GitLab"
      )

    api = api_request_log_fixture(account: account, actor_id: admin.id, method: "POST", path: "/resources")
    other = change_log_fixture(account: account_fixture(), subject: subject_for(admin))

    {:ok, lv, html} = conn |> authorize_conn(admin) |> live(~p"/#{account}/activity")

    assert html =~ "Removed"
    assert html =~ "Lee Chen"
    assert html =~ "On-call"
    assert html =~ "POST /resources"
    assert html =~ "GitLab"
    refute html =~ other.log_id

    ids =
      lv
      |> element("#activity-stream tbody")
      |> render()
      |> Floki.parse_fragment!()
      |> Floki.find("tr")
      |> Enum.map(&(&1 |> Floki.attribute("id") |> List.first()))

    expected = [
      "activity-event-api-#{api.log_id}",
      "activity-event-change-#{change.log_id}",
      "activity-event-flow-#{flow.log_id}",
      "activity-event-session-#{session.log_id}"
    ]

    # Signing in for the test writes a session log of its own.
    assert Enum.filter(ids, &(&1 in expected)) == expected
  end

  test "filters by type and search", %{conn: conn, account: account, admin: admin} do
    change = change_log_fixture(account: account, subject: subject_for(admin), object: "resources")
    api = api_request_log_fixture(account: account, actor_id: admin.id, path: "/policies")

    conn = authorize_conn(conn, admin)

    {:ok, lv, _html} = live(conn, ~p"/#{account}/activity?#{[types: ["api"]]}")
    assert has_element?(lv, "#activity-event-api-#{api.log_id}")
    refute has_element?(lv, "#activity-event-change-#{change.log_id}")
    assert has_element?(lv, "#activity-chip-types")

    lv |> form("#activity-filters", %{"q" => "policies"}) |> render_change()
    assert_patch(lv)
    assert has_element?(lv, "#activity-event-api-#{api.log_id}")

    lv |> form("#activity-filters", %{"q" => "nothing-matches-this"}) |> render_change()
    assert has_element?(lv, "#activity-empty")
  end

  test "time range hides older events", %{conn: conn, account: account, admin: admin} do
    old = api_request_log_fixture(account: account, actor_id: admin.id, inserted_at: ago(3 * 86_400))

    conn = authorize_conn(conn, admin)

    {:ok, lv, _html} = live(conn, ~p"/#{account}/activity")
    refute has_element?(lv, "#activity-event-api-#{old.log_id}")

    {:ok, lv, _html} = live(conn, ~p"/#{account}/activity?range=7d")
    assert has_element?(lv, "#activity-event-api-#{old.log_id}")
  end

  test "pivots on a person from a row and removes the chip", %{
    conn: conn,
    account: account,
    admin: admin,
    person: person
  } do
    mine = flow_log_fixture(account: account, initiator_actor_id: person.id, initiator_actor_name: person.name)
    theirs = flow_log_fixture(account: account, initiator_actor_id: Ecto.UUID.generate())

    {:ok, lv, _html} = conn |> authorize_conn(admin) |> live(~p"/#{account}/activity")
    assert has_element?(lv, "#activity-event-flow-#{theirs.log_id}")

    lv
    |> element("#activity-event-flow-#{mine.log_id} button[phx-value-kind='actor']")
    |> render_click()

    path = assert_patch(lv)
    assert path =~ "pivot"
    assert has_element?(lv, "#activity-pivot-actor-#{person.id}", "Lee Chen")
    assert has_element?(lv, "#activity-event-flow-#{mine.log_id}")
    refute has_element?(lv, "#activity-event-flow-#{theirs.log_id}")

    lv |> element("#activity-pivot-actor-#{person.id} button") |> render_click()
    assert_patch(lv)
    assert has_element?(lv, "#activity-event-flow-#{theirs.log_id}")
  end

  test "ignores invalid pivots", %{conn: conn, account: account, admin: admin} do
    {:ok, lv, _html} =
      conn
      |> authorize_conn(admin)
      |> live(~p"/#{account}/activity?#{[pivot: ["actor:not-a-uuid", "bogus:#{Ecto.UUID.generate()}"]]}")

    refute has_element?(lv, "[id^='activity-pivot-']")
  end

  test "opens an event in a modal with related events", %{
    conn: conn,
    account: account,
    admin: admin,
    person: person
  } do
    device_id = Ecto.UUID.generate()

    session =
      session_log_fixture(
        account: account,
        timestamp: ago(120),
        subject: subject_for(person) |> Map.put("device_id", device_id)
      )

    flow =
      flow_log_fixture(
        account: account,
        flow_start: ago(60),
        initiator_actor_id: person.id,
        initiator_device_id: device_id,
        initiator_actor_name: person.name
      )

    unrelated = flow_log_fixture(account: account, flow_start: ago(30))

    {:ok, lv, _html} = conn |> authorize_conn(admin) |> live(~p"/#{account}/activity")

    lv |> element("#activity-event-flow-#{flow.log_id}") |> render_click()
    assert_patch(lv)

    assert has_element?(lv, "#activity-event-panel [role='dialog']")
    assert has_element?(lv, "#related-flow-#{flow.log_id}")
    assert has_element?(lv, "#related-session-#{session.log_id}")
    refute has_element?(lv, "#related-flow-#{unrelated.log_id}")
    assert has_element?(lv, "#activity-pivot-add-actor-#{person.id}")
    assert has_element?(lv, "#activity-full-record[href$='/logs/flow_logs/#{flow.log_id}']")

    lv |> element("#activity-pivot-add-actor-#{person.id}") |> render_click()
    assert_patch(lv)
    refute has_element?(lv, "#activity-event-panel [role='dialog']")
    assert has_element?(lv, "#activity-pivot-actor-#{person.id}")
  end

  test "opens an event from a direct link and closes it", %{conn: conn, account: account, admin: admin} do
    api = api_request_log_fixture(account: account, actor_id: admin.id, inserted_at: ago(3 * 86_400))

    {:ok, lv, _html} =
      conn |> authorize_conn(admin) |> live(~p"/#{account}/activity?event=api:#{api.log_id}")

    assert has_element?(lv, "#activity-event-panel [role='dialog']", "Received")

    lv |> element("#activity-event-panel button[title='Close (Esc)']") |> render_click()
    assert_patch(lv)
    refute has_element?(lv, "#activity-event-panel [role='dialog']")
  end

  test "loads older events", %{conn: conn, account: account, admin: admin} do
    logs =
      for i <- 1..55 do
        api_request_log_fixture(account: account, actor_id: admin.id, inserted_at: ago(i * 10))
      end

    oldest = List.last(logs)

    {:ok, lv, _html} = conn |> authorize_conn(admin) |> live(~p"/#{account}/activity")
    refute has_element?(lv, "#activity-event-api-#{oldest.log_id}")

    lv |> element("#activity-load-older") |> render_click()
    assert has_element?(lv, "#activity-event-api-#{oldest.log_id}")
    refute has_element?(lv, "#activity-load-older")
  end
end
