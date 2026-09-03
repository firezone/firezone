defmodule PortalWeb.Logs.FlowLogsTest do
  use PortalWeb.ConnCase, async: true

  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.FlowLogFixtures

  setup do
    account = account_fixture()
    actor = admin_actor_fixture(account: account)
    %{account: account, actor: actor}
  end

  describe "index" do
    test "renders the empty flow logs table", %{conn: conn, account: account, actor: actor} do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/logs/flow_logs")

      assert html =~ "No flow logs"
      refute html =~ "coming soon"
    end

    test "lists each reporting side separately", %{conn: conn, account: account, actor: actor} do
      identity = %{
        account: account,
        policy_authorization_id: Ecto.UUID.generate(),
        initiator_device_id: Ecto.UUID.generate(),
        responder_device_id: Ecto.UUID.generate(),
        resource_id: Ecto.UUID.generate(),
        flow_start: ~U[2026-07-30 10:00:00.000000Z],
        flow_end: ~U[2026-07-30 10:01:00.000000Z],
        outers: [
          %{src_ip: "203.0.113.10", src_port: 51_820, dst_ip: "198.51.100.5", dst_port: 51_820}
        ],
        tx_bytes: 1_600_000,
        rx_bytes: 10_400_000
      }

      initiator = flow_log_fixture(Map.put(identity, :role, :initiator))

      responder =
        flow_log_fixture(
          identity
          |> Map.put(:role, :responder)
          |> Map.put(:flow_start, ~U[2026-07-30 10:00:01.000000Z])
          |> Map.put(:flow_end, ~U[2026-07-30 10:01:02.000000Z])
        )

      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/logs/flow_logs")

      assert html =~ initiator.log_id
      assert html =~ responder.log_id
      assert html =~ "Initiator"
      assert html =~ "Responder"
      assert html =~ "Some User"
      assert html =~ "user@example.com"
      assert html =~ "203.0.113.10"
      assert html =~ "GitLab"

      assert has_element?(lv, "#flow_logs-header th", "Opened")
      assert has_element?(lv, "#flow_logs-header th", "Actor")
      assert has_element?(lv, "#flow_logs-header th", "Client")
      assert has_element?(lv, "#flow_logs-header th", "Resource")
      assert has_element?(lv, "#flow_logs-header th", "Duration")
      assert has_element?(lv, "#flow_logs-header th", "Size")
      refute has_element?(lv, "#flow_logs-header th", "Initiator")
      refute has_element?(lv, "#flow_logs-header th", "Destination")
      refute has_element?(lv, "#flow_logs-header th", "Last packet")
      refute has_element?(lv, "#flow_logs-header th", "Logged by")
      refute has_element?(lv, "#flow_logs-header th", "Protocol")
      refute has_element?(lv, "#flow_logs-header th", "Clock skew")

      assert has_element?(lv, "#flow-log-#{initiator.log_id}", "12.0 MB")

      assert has_element?(
               lv,
               "#flow_logs-header button[phx-value-order_by='flow_logs:asc:total_bytes']"
             )

      initiator_row = lv |> element("#flow-log-#{initiator.log_id}") |> render()
      responder_row = lv |> element("#flow-log-#{responder.log_id}") |> render()
      assert initiator_row =~ "!bg-brand/[0.025]"
      assert initiator_row =~ "dark:!bg-brand/[0.04]"
      assert responder_row =~ "!bg-accent/[0.025]"
      assert responder_row =~ "dark:!bg-accent/[0.04]"

      assert has_element?(lv, "#flow_logs-role-initiator[type='radio'][value='initiator']")
      assert has_element?(lv, "#flow_logs-role-responder[type='radio'][value='responder']")
      refute has_element?(lv, "#flow_logs-protocol-tcp")
      refute has_element?(lv, "#flow_logs-protocol-udp")
    end

    test "sorts by total size", %{conn: conn, account: account, actor: actor} do
      smallest =
        flow_log_fixture(
          account: account,
          tx_bytes: 40,
          rx_bytes: 60,
          flow_start: ~U[2026-07-30 10:00:00.000000Z]
        )

      largest =
        flow_log_fixture(
          account: account,
          tx_bytes: 200,
          rx_bytes: 300,
          flow_start: ~U[2026-07-30 10:01:00.000000Z]
        )

      middle =
        flow_log_fixture(
          account: account,
          tx_bytes: 80,
          rx_bytes: 120,
          flow_start: ~U[2026-07-30 10:02:00.000000Z]
        )

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(
          ~p"/#{account}/logs/flow_logs?flow_logs_order_by=flow_logs:desc:total_bytes"
        )

      row_ids =
        html
        |> Floki.parse_fragment!()
        |> Floki.find("#flow_logs-rows > tr")
        |> Floki.attribute("id")

      assert row_ids == [
               "flow-log-#{largest.log_id}",
               "flow-log-#{middle.log_id}",
               "flow-log-#{smallest.log_id}"
             ]
    end

    test "filters on flow_start and reporting role", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      initiator =
        flow_log_fixture(
          account: account,
          role: :initiator,
          protocol: :tcp,
          flow_start: ~U[2026-07-30 10:00:00.000000Z],
          flow_end: ~U[2026-07-30 10:01:00.000000Z]
        )

      responder =
        flow_log_fixture(
          account: account,
          role: :responder,
          flow_start: ~U[2026-07-29 10:00:00.000000Z],
          flow_end: ~U[2026-07-29 10:01:00.000000Z]
        )

      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(
          ~p"/#{account}/logs/flow_logs?flow_logs_filter[role]=initiator&flow_logs_filter[timestamp][from]=2026-07-30T00:00:00Z"
        )

      assert has_element?(lv, "#flow_logs-role-initiator[checked]")
      assert html =~ initiator.log_id
      refute html =~ responder.log_id
    end

    test "filters by protocol and destination port in one input", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      tcp_443 = flow_log_fixture(account: account, protocol: :tcp, inner_dst_port: 443)
      udp_443 = flow_log_fixture(account: account, protocol: :udp, inner_dst_port: 443)
      udp_53 = flow_log_fixture(account: account, protocol: :udp, inner_dst_port: 53)

      conn = authorize_conn(conn, actor)

      {:ok, lv, html} =
        live(
          conn,
          ~p"/#{account}/logs/flow_logs?flow_logs_filter[protocol_port]=tcp/443"
        )

      assert has_element?(
               lv,
               "input[type='text'][name='flow_logs[protocol_port]'][placeholder='Port or tcp/443'][value='tcp/443']"
             )

      assert html =~ tcp_443.log_id
      refute html =~ udp_443.log_id
      refute html =~ udp_53.log_id

      {:ok, _lv, port_html} =
        live(conn, ~p"/#{account}/logs/flow_logs?flow_logs_filter[protocol_port]=53")

      assert port_html =~ udp_53.log_id
      refute port_html =~ tcp_443.log_id
      refute port_html =~ udp_443.log_id
    end

    test "searches inner and WireGuard IPs with the compact port filter", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      matching =
        flow_log_fixture(
          account: account,
          inner_dst_ip: %Postgrex.INET{address: {10, 20, 30, 40}},
          inner_dst_port: 8_443,
          outers: [
            %{src_ip: "203.0.113.77", src_port: 51_820, dst_ip: "198.51.100.5", dst_port: 51_820}
          ]
        )

      wrong_port =
        flow_log_fixture(
          account: account,
          inner_dst_ip: %Postgrex.INET{address: {10, 20, 30, 40}},
          inner_dst_port: 443,
          outers: [
            %{src_ip: "203.0.113.77", src_port: 51_820, dst_ip: "198.51.100.5", dst_port: 51_820}
          ]
        )

      wrong_ip =
        flow_log_fixture(
          account: account,
          inner_dst_ip: %Postgrex.INET{address: {10, 20, 30, 41}},
          inner_dst_port: 8_443,
          outers: [
            %{src_ip: "203.0.113.78", src_port: 51_820, dst_ip: "198.51.100.5", dst_port: 51_820}
          ]
        )

      conn = authorize_conn(conn, actor)

      {:ok, lv, html} =
        live(
          conn,
          ~p"/#{account}/logs/flow_logs?flow_logs_filter[search]=203.0.113.77&flow_logs_filter[protocol_port]=8443"
        )

      assert has_element?(
               lv,
               "input[type='text'][name='flow_logs[protocol_port]'][value='8443']"
             )

      assert html =~ matching.log_id
      refute html =~ wrong_port.log_id
      refute html =~ wrong_ip.log_id

      {:ok, _lv, inner_ip_html} =
        live(
          conn,
          ~p"/#{account}/logs/flow_logs?flow_logs_filter[search]=10.20.30.40&flow_logs_filter[protocol_port]=8443"
        )

      assert inner_ip_html =~ matching.log_id
      refute inner_ip_html =~ wrong_port.log_id
      refute inner_ip_html =~ wrong_ip.log_id
    end

    test "hides incomplete flows by default and includes them with a toggle", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      complete = flow_log_fixture(account: account)
      incomplete = flow_log_fixture(account: account, flow_end: nil)
      conn = authorize_conn(conn, actor)

      {:ok, lv, html} = live(conn, ~p"/#{account}/logs/flow_logs")

      assert has_element?(lv, "#flow_logs-show_incomplete-toggle:not([checked])")
      assert html =~ complete.log_id
      refute html =~ incomplete.log_id

      html = toggle_show_incomplete(lv, "true")

      assert has_element?(lv, "#flow_logs-show_incomplete-toggle[checked]")
      assert html =~ complete.log_id
      assert html =~ incomplete.log_id
      assert has_element?(lv, "#flow-log-#{incomplete.log_id}", "Incomplete")

      html = toggle_show_incomplete(lv, "false")

      assert has_element?(lv, "#flow_logs-show_incomplete-toggle:not([checked])")
      assert html =~ complete.log_id
      refute html =~ incomplete.log_id

      {:ok, lv, html} =
        live(
          conn,
          ~p"/#{account}/logs/flow_logs?flow_logs_filter[show_incomplete]=true"
        )

      assert has_element?(lv, "#flow_logs-show_incomplete-toggle[checked]")
      assert html =~ complete.log_id
      assert html =~ incomplete.log_id
    end

    test "shows clock skew in the duration cell", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      log =
        flow_log_fixture(
          account: account,
          flow_start: ~U[2026-07-30 10:01:00.000000Z],
          flow_end: ~U[2026-07-30 10:00:00.000000Z]
        )

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/logs/flow_logs")

      assert has_element?(
               lv,
               "#flow-log-#{log.log_id} [title*='reported flow end time is earlier']",
               "Clock skew"
             )
    end
  end

  describe "show" do
    test "renders outer paths as an ordered history", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      log =
        flow_log_fixture(
          account: account,
          outers: [
            %{
              src_ip: "192.0.2.10",
              src_port: 41_001,
              dst_ip: "198.51.100.10",
              dst_port: 51_820
            },
            %{
              src_ip: nil,
              src_port: nil,
              dst_ip: "198.51.100.11",
              dst_port: 51_820
            },
            %{
              src_ip: "2001:db8::10",
              src_port: 41_003,
              dst_ip: "2001:db8::20",
              dst_port: 51_820,
              path_activated_at: ~U[2026-07-30 10:00:30.000000Z]
            }
          ]
        )

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/logs/flow_logs/#{log.log_id}")

      history_selector = "#flow-log-path-history-#{log.log_id}"
      history = lv |> element(history_selector) |> render() |> Floki.parse_fragment!()

      assert has_element?(lv, history_selector, "3 paths")
      assert has_element?(lv, "#{history_selector} [data-wireguard-path='1']", "Initial path")
      assert has_element?(lv, "#{history_selector} [data-wireguard-path='2']", "Path change")

      assert history
             |> Floki.find("[data-wireguard-path]")
             |> Enum.flat_map(&Floki.attribute(&1, "data-wireguard-path")) == ["1", "2", "3"]

      assert history
             |> Floki.find("[data-wireguard-endpoint='initiator']")
             |> Enum.map(&(&1 |> Floki.text() |> String.trim())) == [
               "192.0.2.10:41001",
               "Not observed",
               "[2001:db8::10]:41003"
             ]

      assert history
             |> Floki.find("[data-wireguard-endpoint='responder']")
             |> Enum.map(&(&1 |> Floki.text() |> String.trim())) == [
               "198.51.100.10:51820",
               "198.51.100.11:51820",
               "[2001:db8::20]:51820"
             ]

      assert has_element?(lv, "#path-activated-3-#{log.log_id}", "7/30/26, 10:00 AM")
      refute has_element?(lv, "#path-activated-1-#{log.log_id}")
    end

    test "shows the full timestamp in a popover", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      log = flow_log_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/logs/flow_logs/#{log.log_id}")

      panel_html = lv |> element("#flow-log-panel") |> render()

      assert has_element?(lv, "#panel-start-#{log.log_id}")
      assert panel_html =~ DateTime.to_iso8601(log.flow_start)
    end

    test "explains when an open flow has no outer paths yet", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      log = flow_log_fixture(account: account, flow_end: nil)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/logs/flow_logs/#{log.log_id}")

      assert has_element?(
               lv,
               "#flow-log-path-history-#{log.log_id}",
               "Paths are reported when the flow closes."
             )
    end

    test "shows a plausible overlapping report without claiming a definite pair", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      identity = %{
        account: account,
        policy_authorization_id: Ecto.UUID.generate(),
        initiator_device_id: Ecto.UUID.generate(),
        responder_device_id: Ecto.UUID.generate(),
        resource_id: Ecto.UUID.generate(),
        protocol: :tcp,
        inner_src_ip: %Postgrex.INET{address: {100, 64, 0, 8}},
        inner_src_port: 51_234,
        inner_dst_ip: %Postgrex.INET{address: {10, 0, 0, 9}},
        inner_dst_port: 443,
        outers: [
          %{
            src_ip: "203.0.113.44",
            src_port: 62_000,
            dst_ip: "189.172.73.153",
            dst_port: 51_820
          }
        ],
        domain: nil
      }

      initiator =
        flow_log_fixture(
          identity
          |> Map.put(:role, :initiator)
          |> Map.put(:flow_start, ~U[2026-07-30 10:00:00.000000Z])
          |> Map.put(:flow_end, ~U[2026-07-30 10:02:00.000000Z])
          |> Map.put(:tx_bytes, 12_500)
        )

      responder =
        flow_log_fixture(
          identity
          |> Map.put(:role, :responder)
          |> Map.put(:flow_start, ~U[2026-07-30 10:00:03.000000Z])
          |> Map.put(:flow_end, ~U[2026-07-30 10:02:05.000000Z])
          |> Map.put(:tx_bytes, 12_000)
        )

      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/logs/flow_logs/#{initiator.log_id}")

      panel_html = lv |> element("#flow-log-panel") |> render()

      assert has_element?(
               lv,
               "#flow-log-panel-title",
               "Some User (user@example.com) GitLab"
             )

      assert html =~ "Flow logs are paired on a best-effort basis."
      assert html =~ "Matching log"
      assert html =~ "Connection details"
      assert panel_html =~ "Flow log JSON"
      assert has_element?(lv, "#flow-log-json .json-key")
      assert has_element?(lv, "#flow-log-json .json-string")
      assert has_element?(lv, "#flow-log-json .json-number")

      assert has_element?(
               lv,
               "#flow-log-json button[data-copy-to-clipboard-target='flow-log-json-code']",
               "Copy"
             )

      api_json =
        panel_html
        |> Floki.parse_fragment!()
        |> Floki.find("#flow-log-json-code")
        |> Floki.text()
        |> JSON.decode!()

      expected_api_json =
        initiator
        |> PortalAPI.JSON.encode()
        |> JSON.encode!()
        |> JSON.decode!()

      assert api_json == expected_api_json
      assert api_json["log_id"] == initiator.log_id
      assert api_json["role"] == "initiator"
      assert api_json["inner_src_ip"] == "100.64.0.8"
      assert api_json["inner_dst_ip"] == "10.0.0.9"
      assert api_json["type"] == "flow"
      assert api_json["timestamp"] == DateTime.to_iso8601(initiator.inserted_at)
      assert api_json["policy_authorization_id"] == initiator.policy_authorization_id
      assert api_json["policy_id"] == initiator.policy_id
      assert Map.has_key?(api_json, "initiator_client_version")
      assert api_json["outers"] == [
               %{
                 "src_ip" => "203.0.113.44",
                 "src_port" => 62_000,
                 "dst_ip" => "189.172.73.153",
                 "dst_port" => 51_820,
                 "path_activated_at" => nil
               }
             ]
      refute Map.has_key?(api_json, "data")
      refute Map.has_key?(api_json, "seq")
      refute Map.has_key?(api_json, "start_seq")
      assert has_element?(
               lv,
               "a[href='https://www.firezone.dev/kb/audit-logs/flow#two-sided-reporting']",
               "Read more"
             )
      assert panel_html =~ initiator.log_id
      assert panel_html =~ responder.log_id
      assert panel_html =~ "12.5 KB"
      assert has_element?(
               lv,
               "#flow-log-path-history-#{initiator.log_id} [data-wireguard-endpoint='initiator']",
               "203.0.113.44:62000"
             )

      assert has_element?(
               lv,
               "#flow-log-path-history-#{initiator.log_id} [data-wireguard-endpoint='responder']",
               "189.172.73.153:51820"
             )

      assert has_element?(lv, "#flow-log-match-#{responder.log_id}[href*='#{responder.log_id}']")
      refute has_element?(lv, "#flow-log-match-#{initiator.log_id}")

      lv
      |> element("#flow-log-match-#{responder.log_id}")
      |> render_click()

      assert_patch(lv, ~p"/#{account}/logs/flow_logs/#{responder.log_id}")
      assert has_element?(lv, "#flow-log-path-history-#{responder.log_id}")
      assert has_element?(lv, "#flow-log-match-#{initiator.log_id}")
      refute has_element?(lv, "#flow-log-match-#{responder.log_id}")
    end

    test "does not match a non-overlapping reused tuple", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      identity = %{
        account: account,
        policy_authorization_id: Ecto.UUID.generate(),
        initiator_device_id: Ecto.UUID.generate(),
        responder_device_id: Ecto.UUID.generate(),
        resource_id: Ecto.UUID.generate(),
        protocol: :udp,
        inner_src_port: 50_000,
        inner_dst_port: 53,
        domain: nil
      }

      selected =
        flow_log_fixture(
          identity
          |> Map.put(:role, :initiator)
          |> Map.put(:flow_start, ~U[2026-07-30 10:00:00.000000Z])
          |> Map.put(:flow_end, ~U[2026-07-30 10:01:00.000000Z])
        )

      other =
        flow_log_fixture(
          identity
          |> Map.put(:role, :responder)
          |> Map.put(:flow_start, ~U[2026-07-30 11:00:00.000000Z])
          |> Map.put(:flow_end, ~U[2026-07-30 11:01:00.000000Z])
        )

      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/logs/flow_logs/#{selected.log_id}")

      panel_html = lv |> element("#flow-log-panel") |> render()

      assert html =~ "No matching responder log"

      assert panel_html
             |> Floki.parse_fragment!()
             |> Floki.text()
             |> String.replace(~r/\s+/, " ") =~ "beyond the retention period"

      refute panel_html =~ other.log_id
    end

    test "matches when NAT rewrote the WireGuard tuple", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      identity = %{
        account: account,
        policy_authorization_id: Ecto.UUID.generate(),
        initiator_device_id: Ecto.UUID.generate(),
        responder_device_id: Ecto.UUID.generate(),
        resource_id: Ecto.UUID.generate(),
        protocol: :tcp,
        inner_src_ip: %Postgrex.INET{address: {100, 64, 0, 8}},
        inner_src_port: 51_234,
        inner_dst_ip: %Postgrex.INET{address: {10, 0, 0, 9}},
        inner_dst_port: 443,
        domain: nil
      }

      selected =
        flow_log_fixture(
          identity
          |> Map.put(:role, :initiator)
          |> Map.put(:outers, [
            %{
              src_ip: "192.168.1.86",
              src_port: 52_625,
              dst_ip: "203.0.113.5",
              dst_port: 52_625
            }
          ])
          |> Map.put(:flow_start, ~U[2026-07-30 10:00:00.000000Z])
          |> Map.put(:flow_end, ~U[2026-07-30 10:01:00.000000Z])
        )

      other =
        flow_log_fixture(
          identity
          |> Map.put(:role, :responder)
          |> Map.put(:outers, [
            %{
              src_ip: "198.51.100.130",
              src_port: 41_001,
              dst_ip: "10.122.5.4",
              dst_port: 52_625
            }
          ])
          |> Map.put(:flow_start, ~U[2026-07-30 10:00:02.000000Z])
          |> Map.put(:flow_end, ~U[2026-07-30 10:01:02.000000Z])
        )

      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/logs/flow_logs/#{selected.log_id}")

      panel_html = lv |> element("#flow-log-panel") |> render()

      refute html =~ "No matching responder log"
      assert panel_html =~ other.log_id
      assert has_element?(lv, "#flow-log-match-#{other.log_id}")

      assert has_element?(
               lv,
               "#flow-log-path-history-#{selected.log_id} [data-wireguard-endpoint='initiator']",
               "192.168.1.86:52625"
             )
    end

    test "matches a DNS Resource flow on its domain, not the proxy IP", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      identity = %{
        account: account,
        policy_authorization_id: Ecto.UUID.generate(),
        initiator_device_id: Ecto.UUID.generate(),
        responder_device_id: Ecto.UUID.generate(),
        resource_id: Ecto.UUID.generate(),
        protocol: :tcp,
        inner_src_ip: %Postgrex.INET{address: {100, 64, 0, 8}},
        inner_src_port: 51_234,
        inner_dst_port: 443,
        domain: "gitlab.company.com"
      }

      selected =
        flow_log_fixture(
          identity
          |> Map.put(:role, :initiator)
          |> Map.put(:inner_dst_ip, %Postgrex.INET{address: {100, 96, 0, 3}})
          |> Map.put(:flow_start, ~U[2026-07-30 10:00:00.000000Z])
          |> Map.put(:flow_end, ~U[2026-07-30 10:01:00.000000Z])
        )

      other =
        flow_log_fixture(
          identity
          |> Map.put(:role, :responder)
          |> Map.put(:inner_dst_ip, %Postgrex.INET{address: {10, 0, 0, 9}})
          |> Map.put(:flow_start, ~U[2026-07-30 10:00:02.000000Z])
          |> Map.put(:flow_end, ~U[2026-07-30 10:01:02.000000Z])
        )

      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/logs/flow_logs/#{selected.log_id}")

      panel_html = lv |> element("#flow-log-panel") |> render()

      refute html =~ "No matching responder log"
      assert panel_html =~ other.log_id
    end

    test "does not match a different destination without a domain", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      identity = %{
        account: account,
        policy_authorization_id: Ecto.UUID.generate(),
        initiator_device_id: Ecto.UUID.generate(),
        responder_device_id: Ecto.UUID.generate(),
        resource_id: Ecto.UUID.generate(),
        protocol: :tcp,
        inner_src_ip: %Postgrex.INET{address: {100, 64, 0, 8}},
        inner_src_port: 51_234,
        inner_dst_port: 443,
        domain: nil
      }

      selected =
        flow_log_fixture(
          identity
          |> Map.put(:role, :initiator)
          |> Map.put(:inner_dst_ip, %Postgrex.INET{address: {10, 0, 0, 9}})
          |> Map.put(:flow_start, ~U[2026-07-30 10:00:00.000000Z])
          |> Map.put(:flow_end, ~U[2026-07-30 10:01:00.000000Z])
        )

      other =
        flow_log_fixture(
          identity
          |> Map.put(:role, :responder)
          |> Map.put(:inner_dst_ip, %Postgrex.INET{address: {10, 0, 0, 10}})
          |> Map.put(:flow_start, ~U[2026-07-30 10:00:02.000000Z])
          |> Map.put(:flow_end, ~U[2026-07-30 10:01:02.000000Z])
        )

      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/logs/flow_logs/#{selected.log_id}")

      panel_html = lv |> element("#flow-log-panel") |> render()

      assert html =~ "No matching responder log"
      refute panel_html =~ other.log_id
    end
  end

  defp toggle_show_incomplete(lv, value) do
    lv
    |> element("#flow_logs-filters")
    |> render_change(%{
      "table_id" => "flow_logs",
      "flow_logs" => %{"show_incomplete" => value}
    })
  end
end
