defmodule PortalWeb.Logs.ChangeLogsTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.ChangeLogFixtures

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)
    actor_subject = %{"actor_id" => Ecto.UUID.generate(), "actor_email" => "user@example.com"}
    %{account: account, actor: actor, actor_subject: actor_subject}
  end

  describe "unauthorized" do
    test "redirects to sign-in when not authenticated", %{conn: conn, account: account} do
      path = ~p"/#{account}/logs/change_logs"

      assert live(conn, path) ==
               {:error,
                {:redirect,
                 %{
                   to: ~p"/#{account}/sign_in?#{%{redirect_to: path}}",
                   flash: %{"error" => "You must sign in to access that page."}
                 }}}
    end
  end

  describe "index" do
    test "renders the Change Logs page", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/logs/change_logs")

      assert html =~ "Change Logs"
      assert html =~ "immutable audit trail of every configuration change"
    end

    test "fresh account shows the unfiltered empty slot, not the filtered one", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/logs/change_logs")

      # The default `show_system: false` is applied to the DB query only;
      # it must not register as an active filter and trigger the
      # "No results found" / Reset state.
      assert html =~ "No change logs"
      refute html =~ "No results found"
    end

    test "lists change logs for the account only", %{
      conn: conn,
      account: account,
      actor: actor,
      actor_subject: actor_subject
    } do
      mine = change_log_fixture(account: account, object: "actors", subject: actor_subject)
      other_account = account_fixture()

      other =
        change_log_fixture(account: other_account, object: "actors", subject: actor_subject)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/logs/change_logs")

      assert html =~ mine.log_id
      assert html =~ "actors"
      refute html =~ other.log_id
    end

    test "shows `system` badge when subject is nil", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      _cl = change_log_fixture(account: account, subject: nil)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/logs/change_logs?change_logs_filter[show_system]=true")

      assert html =~ "system"
    end

    test "renders actor name when subject has one", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      _cl =
        change_log_fixture(
          account: account,
          subject: %{
            "actor_name" => "Alice Admin",
            "actor_email" => "alice@example.com",
            "actor_id" => Ecto.UUID.generate()
          }
        )

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/logs/change_logs")

      assert html =~ "Alice Admin"
    end

    test "actor_cell falls back to email when actor_name is missing", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      _cl =
        change_log_fixture(
          account: account,
          subject: %{"actor_email" => "noname@example.com"}
        )

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/logs/change_logs")

      assert html =~ "noname@example.com"
    end

    test "actor_cell and subject_section degrade to system when no identifying fields", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      cl =
        change_log_fixture(
          account: account,
          subject: %{"ip" => "203.0.113.7"}
        )

      conn = authorize_conn(conn, actor)

      # Index: actor_cell with a non-nil but identityless subject renders the
      # "system" fallback (the bare-empty-subject path, distinct from subject=nil).
      {:ok, _lv, index_html} =
        live(conn, ~p"/#{account}/logs/change_logs?change_logs_filter[show_system]=true")

      assert index_html =~ cl.log_id
      assert index_html =~ "system"

      # Side panel: subject_section with subject={"ip"=>...} renders the IP row
      # in the Subject section (covering the `:if={@rows != []}` branch).
      {:ok, _lv, show_html} =
        live(
          conn,
          ~p"/#{account}/logs/change_logs/#{cl.log_id}?change_logs_filter[show_system]=true"
        )

      assert show_html =~ "203.0.113.7"
    end

    test "actor_card renders 'Deleted actor' fallback when subject has no name/email", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      cl =
        change_log_fixture(
          account: account,
          subject: %{"unknown_field" => "value"}
        )

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(
          ~p"/#{account}/logs/change_logs/#{cl.log_id}?change_logs_filter[show_system]=true"
        )

      assert html =~ "Deleted actor"
    end

    test "filters by operation via the operation button group", %{
      conn: conn,
      account: account,
      actor: actor,
      actor_subject: actor_subject
    } do
      insert_cl =
        change_log_fixture(
          account: account,
          operation: :insert,
          object: "actors",
          subject: actor_subject
        )

      update_cl =
        change_log_fixture(
          account: account,
          operation: :update,
          object: "actors",
          before: %{"name" => "Old"},
          after: %{"name" => "New"},
          subject: actor_subject
        )

      delete_cl =
        change_log_fixture(
          account: account,
          operation: :delete,
          object: "actors",
          before: %{"name" => "Gone"},
          after: nil,
          subject: actor_subject
        )

      conn = authorize_conn(conn, actor)

      for {value, want, deny} <- [
            {"update", update_cl, [insert_cl, delete_cl]},
            {"insert", insert_cl, [update_cl, delete_cl]},
            {"delete", delete_cl, [insert_cl, update_cl]}
          ] do
        {:ok, _lv, html} =
          live(conn, ~p"/#{account}/logs/change_logs?change_logs_filter[operation]=#{value}")

        assert html =~ want.log_id, "operation=#{value} should show #{want.log_id}"

        for d <- deny do
          refute html =~ d.log_id, "operation=#{value} should hide #{d.log_id}"
        end
      end
    end

    test "combines operation and object filters", %{
      conn: conn,
      account: account,
      actor: actor,
      actor_subject: actor_subject
    } do
      hit =
        change_log_fixture(
          account: account,
          operation: :update,
          object: "actors",
          before: %{"x" => 1},
          after: %{"x" => 2},
          subject: actor_subject
        )

      wrong_op =
        change_log_fixture(
          account: account,
          operation: :insert,
          object: "actors",
          subject: actor_subject
        )

      wrong_obj =
        change_log_fixture(
          account: account,
          operation: :update,
          object: "policies",
          before: %{"x" => 1},
          after: %{"x" => 2},
          subject: actor_subject
        )

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(
          ~p"/#{account}/logs/change_logs?change_logs_filter[operation]=update&change_logs_filter[object][]=actors"
        )

      assert html =~ hit.log_id
      refute html =~ wrong_op.log_id
      refute html =~ wrong_obj.log_id
    end

    test "filters by object via the object multi-select", %{
      conn: conn,
      account: account,
      actor: actor,
      actor_subject: actor_subject
    } do
      actor_cl = change_log_fixture(account: account, object: "actors", subject: actor_subject)
      policy_cl = change_log_fixture(account: account, object: "policies", subject: actor_subject)
      site_cl = change_log_fixture(account: account, object: "sites", subject: actor_subject)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(
          ~p"/#{account}/logs/change_logs?change_logs_filter[object][]=actors&change_logs_filter[object][]=policies"
        )

      assert html =~ actor_cl.log_id
      assert html =~ policy_cl.log_id
      refute html =~ site_cl.log_id
    end

    test "reset button clears all filters", %{
      conn: conn,
      account: account,
      actor: actor,
      actor_subject: actor_subject
    } do
      cl_a = change_log_fixture(account: account, object: "actors", subject: actor_subject)
      cl_b = change_log_fixture(account: account, object: "policies", subject: actor_subject)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/logs/change_logs?change_logs_filter[object][]=actors")

      assert render(lv) =~ cl_a.log_id
      refute render(lv) =~ cl_b.log_id

      lv
      |> element("button[phx-click='filter'][title='Clear all filters']")
      |> render_click()

      html = render(lv)
      assert html =~ cl_a.log_id
      assert html =~ cl_b.log_id
    end

    test "hides system updates by default", %{
      conn: conn,
      account: account,
      actor: actor,
      actor_subject: actor_subject
    } do
      system_cl = change_log_fixture(account: account, subject: nil)
      actor_cl = change_log_fixture(account: account, subject: actor_subject)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/logs/change_logs")

      assert html =~ actor_cl.log_id
      refute html =~ system_cl.log_id
    end

    test "datetime mode without bounds is treated as no-op", %{
      conn: conn,
      account: account,
      actor: actor,
      actor_subject: actor_subject
    } do
      cl = change_log_fixture(account: account, subject: actor_subject)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(
          ~p"/#{account}/logs/change_logs?change_logs_filter[timestamp][mode]=local&change_logs_filter[show_system]=true"
        )

      assert html =~ cl.log_id
      refute html =~ "invalid pagination filter"
    end

    test "mode-only URL params re-render the Local pill as active and propagate tz_mode to cells",
         %{
           conn: conn,
           account: account,
           actor: actor,
           actor_subject: actor_subject
         } do
      cl = change_log_fixture(account: account, subject: actor_subject)

      conn = authorize_conn(conn, actor)

      # UTC by default
      {:ok, lv, _html} = live(conn, ~p"/#{account}/logs/change_logs")
      assert has_element?(lv, "#change_logs-timestamp-mode-utc[checked]")
      assert has_element?(lv, "#timestamp-#{cl.log_id}[data-tz-mode='utc']")

      # mode=local in URL flips both the radio and the cell's data-tz-mode
      {:ok, lv, _html} =
        live(conn, ~p"/#{account}/logs/change_logs?change_logs_filter[timestamp][mode]=local")

      assert has_element?(lv, "#change_logs-timestamp-mode-local[checked]")
      refute has_element?(lv, "#change_logs-timestamp-mode-utc[checked]")
      assert has_element?(lv, "#timestamp-#{cl.log_id}[data-tz-mode='local']")
    end

    test "toggling mode via form change re-renders the cell text in the browser's TZ", %{
      conn: conn,
      account: account,
      actor: actor,
      actor_subject: actor_subject
    } do
      # 2026-05-30 12:00 UTC == 2026-05-30 08:00 in America/New_York (EDT)
      cl =
        change_log_fixture(
          account: account,
          subject: actor_subject,
          timestamp: ~U[2026-05-30 12:00:00.000000Z]
        )

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> Phoenix.LiveViewTest.put_connect_params(%{"timezone" => "America/New_York"})
        |> live(~p"/#{account}/logs/change_logs")

      initial = lv |> element("#timestamp-#{cl.log_id}") |> render()
      assert initial =~ "12:00 PM"
      refute initial =~ "8:00 AM"

      lv
      |> form("form[phx-change='filter']", change_logs: %{timestamp: %{mode: "local"}})
      |> render_change()

      shifted = lv |> element("#timestamp-#{cl.log_id}") |> render()
      assert shifted =~ "8:00 AM"
      refute shifted =~ "12:00 PM"
    end

    test "shows system updates when toggle is on", %{
      conn: conn,
      account: account,
      actor: actor,
      actor_subject: actor_subject
    } do
      system_cl = change_log_fixture(account: account, subject: nil)
      actor_cl = change_log_fixture(account: account, subject: actor_subject)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/logs/change_logs?change_logs_filter[show_system]=true")

      assert html =~ actor_cl.log_id
      assert html =~ system_cl.log_id
    end

    test "actor search matches actor_email, actor_name, actor_id, and log_id hex", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      alice_id = Ecto.UUID.generate()
      bob_id = Ecto.UUID.generate()

      alice =
        change_log_fixture(
          account: account,
          subject: %{
            "actor_name" => "Alice Admin",
            "actor_email" => "alice@example.com",
            "actor_id" => alice_id
          }
        )

      bob =
        change_log_fixture(
          account: account,
          subject: %{
            "actor_name" => "Bob Boss",
            "actor_email" => "bob@example.com",
            "actor_id" => bob_id
          }
        )

      {:ok, lv, _html} = conn |> authorize_conn(actor) |> live(~p"/#{account}/logs/change_logs")

      # Fixture log_ids share their leading bytes (the boot-timestamp prefix is
      # the same for fixtures created microseconds apart), so probe the unique
      # tail of the log_id rather than the head.
      alice_tail = String.slice(alice.log_id, 16, 8)

      for query <- ["alice@", "Alice Admin", alice_id, alice_tail] do
        html =
          lv
          |> form("form[phx-change='filter']", change_logs: %{actor: query})
          |> render_change()

        assert html =~ alice.log_id, "expected alice match for query=#{inspect(query)}"
        refute html =~ bob.log_id, "expected bob NOT to match for query=#{inspect(query)}"
      end
    end

    test "sorts by log_id and timestamp via the sortable column headers", %{
      conn: conn,
      account: account,
      actor: actor,
      actor_subject: actor_subject
    } do
      older =
        change_log_fixture(
          account: account,
          timestamp: ~U[2026-05-30 12:00:00.000000Z],
          subject: actor_subject
        )

      newer =
        change_log_fixture(
          account: account,
          timestamp: ~U[2026-06-01 12:00:00.000000Z],
          subject: actor_subject
        )

      conn = authorize_conn(conn, actor)
      base = ~p"/#{account}/logs/change_logs"

      # Format: "{assoc}:{dir}:{field}" per LiveTable.parse_order_by.
      for column <- ["timestamp", "log_id"], dir <- ["desc", "asc"] do
        path = "#{base}?change_logs_order_by=change_logs:#{dir}:#{column}"

        {:ok, _lv, html} = live(conn, path)

        newer_pos = :binary.match(html, newer.log_id) |> elem(0)
        older_pos = :binary.match(html, older.log_id) |> elem(0)

        case dir do
          "desc" ->
            assert newer_pos < older_pos,
                   "#{column} desc: newer should appear before older"

          "asc" ->
            assert older_pos < newer_pos,
                   "#{column} asc: older should appear before newer"
        end
      end
    end

    test "filters by timestamp range bounds", %{
      conn: conn,
      account: account,
      actor: actor,
      actor_subject: actor_subject
    } do
      yesterday = ~U[2026-05-30 12:00:00.000000Z]
      today = ~U[2026-06-01 12:00:00.000000Z]
      tomorrow = ~U[2026-06-02 12:00:00.000000Z]

      old_cl =
        change_log_fixture(account: account, timestamp: yesterday, subject: actor_subject)

      mid_cl =
        change_log_fixture(account: account, timestamp: today, subject: actor_subject)

      new_cl =
        change_log_fixture(account: account, timestamp: tomorrow, subject: actor_subject)

      conn = authorize_conn(conn, actor)

      # from-bound only: includes today + tomorrow, excludes yesterday
      from = "2026-06-01T00:00:00"

      {:ok, _lv, html} =
        live(
          conn,
          ~p"/#{account}/logs/change_logs?change_logs_filter[timestamp][from]=#{from}&change_logs_filter[timestamp][mode]=utc"
        )

      assert html =~ mid_cl.log_id
      assert html =~ new_cl.log_id
      refute html =~ old_cl.log_id

      # to-bound only: includes yesterday + today, excludes tomorrow
      to = "2026-06-02T00:00:00"

      {:ok, _lv, html} =
        live(
          conn,
          ~p"/#{account}/logs/change_logs?change_logs_filter[timestamp][to]=#{to}&change_logs_filter[timestamp][mode]=utc"
        )

      assert html =~ old_cl.log_id
      assert html =~ mid_cl.log_id
      refute html =~ new_cl.log_id

      # both bounds: includes only today
      {:ok, _lv, html} =
        live(
          conn,
          ~p"/#{account}/logs/change_logs?change_logs_filter[timestamp][from]=#{from}&change_logs_filter[timestamp][to]=#{to}&change_logs_filter[timestamp][mode]=utc"
        )

      assert html =~ mid_cl.log_id
      refute html =~ old_cl.log_id
      refute html =~ new_cl.log_id
    end
  end

  describe "show" do
    test "opens side panel with details sidebar and inline diff for an update", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      cl =
        change_log_fixture(
          account: account,
          operation: :update,
          object: "actors",
          before: %{"name" => "Old", "color" => "blue"},
          after: %{"name" => "New", "color" => "blue"}
        )

      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/logs/change_logs/#{cl.log_id}")

      assert has_element?(lv, "#change-log-panel.translate-x-0")
      # Panel title renders the operation badge + object instead of raw log_id.
      assert has_element?(lv, "#change-log-panel", "Update")
      assert has_element?(lv, "#change-log-panel", "actors")
      assert html =~ cl.log_id
      # Details sidebar
      assert html =~ "Timestamp"
      # Diff is rendered server-side as a tree of <li> elements with the
      # json-diff-* class contract the CSS targets.
      assert has_element?(lv, ".json-diff .json-diff-modified")
      assert html =~ "Old"
      assert html =~ "New"
    end

    test "close_panel patches back to the index", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      cl =
        change_log_fixture(
          account: account,
          operation: :update,
          before: %{"name" => "Old"},
          after: %{"name" => "New"}
        )

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/logs/change_logs/#{cl.log_id}")

      render_click(lv, "close_panel")
      assert_patch(lv, ~p"/#{account}/logs/change_logs")
    end

    test "Escape key closes the panel", %{conn: conn, account: account, actor: actor} do
      cl =
        change_log_fixture(
          account: account,
          operation: :update,
          before: %{"name" => "Old"},
          after: %{"name" => "New"}
        )

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/logs/change_logs/#{cl.log_id}")

      lv
      |> element("#change-log-panel")
      |> render_keydown(%{"key" => "Escape"})

      assert_patch(lv, ~p"/#{account}/logs/change_logs")
    end

    test "non-Escape keydown on the panel is a no-op", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      cl =
        change_log_fixture(
          account: account,
          operation: :update,
          before: %{"name" => "Old"},
          after: %{"name" => "New"}
        )

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/logs/change_logs/#{cl.log_id}")

      # The keydown handler's catch-all returns :noreply without patching.
      render_hook(lv, "handle_keydown", %{"key" => "ArrowDown"})

      # Panel still open at the same URL, no patch triggered.
      assert has_element?(lv, "#change-log-panel.translate-x-0")
    end

    test "redirects when change log does not exist", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      missing = Portal.Types.LogId.build_change_log(0, 0)

      assert {:error, {:live_redirect, %{to: to}}} =
               conn
               |> authorize_conn(actor)
               |> live(~p"/#{account}/logs/change_logs/#{missing}")

      assert to == ~p"/#{account}/logs/change_logs"
    end

    test "redirects when path log_id is the right length but not hex", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      malformed = String.duplicate("z", 24)

      assert {:error, {:live_redirect, %{to: to}}} =
               conn
               |> authorize_conn(actor)
               |> live(~p"/#{account}/logs/change_logs/#{malformed}")

      assert to == ~p"/#{account}/logs/change_logs"
    end

    test "side panel for an insert renders the green Insert label", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      cl =
        change_log_fixture(
          account: account,
          operation: :insert,
          object: "actors",
          before: nil,
          after: %{"name" => "Charlie"}
        )

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/logs/change_logs/#{cl.log_id}")

      assert html =~ ~r/bg-success-light[^>]*>\s*Insert/
    end

    test "side panel timestamp is the absolute mode-aware form, not a relative 'ago' string", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      cl =
        change_log_fixture(
          account: account,
          operation: :update,
          object: "actors",
          timestamp: ~U[2026-05-30 12:00:00.000000Z],
          before: %{"x" => 1},
          after: %{"x" => 2}
        )

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/logs/change_logs/#{cl.log_id}")

      assert has_element?(lv, "#panel-timestamp-#{cl.log_id}[data-tz-mode='utc']")

      # Server-rendered text is the absolute short_datetime form, not "X ago".
      panel_html = lv |> element("#panel-timestamp-#{cl.log_id}") |> render()
      refute panel_html =~ "ago"
      assert panel_html =~ "5/30/26"
    end

    test "side panel for a delete renders the red Delete label", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      cl =
        change_log_fixture(
          account: account,
          operation: :delete,
          object: "actors",
          before: %{"name" => "Charlie"},
          after: nil
        )

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/logs/change_logs/#{cl.log_id}")

      assert html =~ ~r/bg-danger-light[^>]*>\s*Delete/
    end
  end

  describe "flow_logs" do
    test "renders the coming soon message", %{conn: conn, account: account, actor: actor} do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/logs/flow_logs")

      assert html =~ "Flow Logs in the portal are coming soon"
      assert html =~ "FIREZONE_FLOW_LOGS=true"
    end
  end
end
