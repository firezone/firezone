defmodule PortalWeb.Settings.LogSinksTest do
  use PortalWeb.ConnCase, async: true
  use Oban.Testing, repo: Portal.Repo

  import Phoenix.LiveViewTest
  import Portal.AccountFixtures
  import Portal.ActorFixtures
  import Portal.LogSinkFixtures

  alias Portal.LogSinkCursor
  alias Portal.Splunk

  setup do
    account = account_fixture(features: %{log_sinks: true})
    actor = admin_actor_fixture(account: account)
    %{account: account, actor: actor}
  end

  defp reload_sink(sink) do
    Repo.get_by!(Splunk.LogSink, account_id: sink.account_id, id: sink.id)
  end

  defp open_sink_actions(lv, sink_id) do
    lv
    |> element("button[phx-click='toggle_sink_actions'][phx-value-id='#{sink_id}']")
    |> render_click()
  end

  describe "unauthorized" do
    test "redirects to sign-in when not authenticated", %{conn: conn, account: account} do
      path = ~p"/#{account}/settings/log_sinks"

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
    test "renders empty state when no log sinks exist", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/log_sinks")

      assert html =~ "Log Sinks"
      assert html =~ "No log sinks configured."
      assert html =~ "Add a log sink"
    end

    test "renders log sinks with status and delivery stats", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      sink =
        splunk_log_sink_fixture(
          account: account,
          name: "SOC Splunk",
          retroactive: true
        )

      now = DateTime.utc_now()

      Repo.insert_all(LogSinkCursor, [
        %{
          account_id: account.id,
          log_sink_id: sink.id,
          stream: :session,
          phase: :live,
          cursor: 100,
          synced_count: 42,
          last_synced_at: now,
          inserted_at: now,
          updated_at: now
        },
        %{
          account_id: account.id,
          log_sink_id: sink.id,
          stream: :session,
          phase: :backfill,
          cursor: 50,
          until_seq: 100,
          synced_count: 50,
          backfill_total: 100,
          inserted_at: now,
          updated_at: now
        }
      ])

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/log_sinks")

      assert html =~ "SOC Splunk"
      assert html =~ "Active"
      assert html =~ "92"
      assert html =~ "50%"
    end

    test "renders error status for sinks disabled by delivery errors", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      splunk_log_sink_fixture(
        account: account,
        is_disabled: true,
        disabled_reason: "Sync error",
        error_message: "Splunk HEC returned HTTP 403: Invalid token",
        errored_at: DateTime.utc_now()
      )

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/log_sinks")

      assert html =~ "Error"
      assert html =~ "Invalid token"
      assert html =~ "Edit and Save this log sink to re-enable it."
    end

    test "shows upgrade prompt when the feature is disabled", %{conn: conn} do
      account = account_fixture(features: %{log_sinks: false})
      actor = admin_actor_fixture(account: account)

      {:ok, _lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/log_sinks")

      assert html =~ "Upgrade to Unlock"
      refute html =~ "No log sinks configured."
    end
  end

  describe "create" do
    test "creates a Splunk log sink with its base row", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/log_sinks/splunk/new")

      form =
        form(lv, "#log-sink-form",
          log_sink: %{
            name: "SOC Splunk",
            collector_url: "https://http-inputs-acme.splunkcloud.com/services/collector/event",
            hec_token: "test-hec-token",
            enabled_streams: ["", "session", "flow"],
            retroactive: "true"
          }
        )

      render_change(form)
      render_submit(form)

      assert sink = Repo.get_by(Splunk.LogSink, account_id: account.id, name: "SOC Splunk")
      assert sink.collector_url == "https://http-inputs-acme.splunkcloud.com"
      assert sink.hec_token == "test-hec-token"
      assert sink.enabled_streams == [:session, :flow]
      assert sink.retroactive

      assert base = Repo.get_by(Portal.LogSink, account_id: account.id, id: sink.id)
      assert base.type == :splunk
    end

    test "creates a Datadog log sink with its base row", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/log_sinks/datadog/new")

      form =
        form(lv, "#log-sink-form",
          log_sink: %{
            name: "SOC Datadog",
            site: "datadoghq.eu",
            api_key: "dd-test-key",
            tags: " env:dev , team:secops ",
            enabled_streams: ["", "change"]
          }
        )

      render_change(form)
      render_submit(form)

      assert sink = Repo.get_by(Portal.Datadog.LogSink, account_id: account.id)
      assert sink.name == "SOC Datadog"
      assert sink.site == "datadoghq.eu"
      assert sink.api_key == "dd-test-key"
      assert sink.tags == "env:dev,team:secops"
      assert sink.enabled_streams == [:change]

      assert base = Repo.get_by(Portal.LogSink, account_id: account.id, id: sink.id)
      assert base.type == :datadog
    end

    test "tags longer than the column used to hold are still accepted", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/log_sinks/datadog/new")

      # Two individually valid tags totalling over 255 chars overflowed the
      # previous varchar(255) column after passing per-tag validation.
      long_tags = "env:#{String.duplicate("a", 150)},team:#{String.duplicate("b", 150)}"

      form =
        form(lv, "#log-sink-form",
          log_sink: %{
            name: "SOC Datadog",
            site: "datadoghq.eu",
            api_key: "dd-test-key",
            tags: long_tags,
            enabled_streams: ["", "change"]
          }
        )

      render_change(form)
      render_submit(form)

      assert sink = Repo.get_by(Portal.Datadog.LogSink, account_id: account.id)
      assert sink.tags == long_tags
    end

    test "tags over the 2000 character cap render a validation error", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/log_sinks/datadog/new")

      long_tags = Enum.map_join(1..11, ",", fn i -> "tag#{i}:#{String.duplicate("a", 190)}" end)

      form =
        form(lv, "#log-sink-form",
          log_sink: %{
            name: "SOC Datadog",
            site: "datadoghq.eu",
            api_key: "dd-test-key",
            tags: long_tags,
            enabled_streams: ["", "change"]
          }
        )

      render_change(form)
      html = render_submit(form)

      assert html =~ "should be at most 2000 character"
      refute Repo.get_by(Portal.Datadog.LogSink, account_id: account.id)
    end

    test "creates a New Relic log sink with its base row", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/log_sinks/newrelic/new")

      form =
        form(lv, "#log-sink-form",
          log_sink: %{
            name: "SOC New Relic",
            region: "EU",
            license_key: "nr-test-key",
            enabled_streams: ["", "session"]
          }
        )

      render_change(form)
      render_submit(form)

      assert sink = Repo.get_by(Portal.NewRelic.LogSink, account_id: account.id)
      assert sink.name == "SOC New Relic"
      assert sink.region == "EU"
      assert sink.license_key == "nr-test-key"
      assert sink.enabled_streams == [:session]

      assert base = Repo.get_by(Portal.LogSink, account_id: account.id, id: sink.id)
      assert base.type == :newrelic
    end

    test "creates an Elastic log sink with its base row", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/log_sinks/elastic/new")

      form =
        form(lv, "#log-sink-form",
          log_sink: %{
            name: "SOC Elastic",
            endpoint_url: "https://acme.es.us-east-1.aws.elastic-cloud.com/_bulk",
            api_key: "es-test-key",
            data_stream: "logs-firezone-default",
            enabled_streams: ["", "session"]
          }
        )

      render_change(form)
      render_submit(form)

      assert sink = Repo.get_by(Portal.Elastic.LogSink, account_id: account.id)
      assert sink.name == "SOC Elastic"
      assert sink.endpoint_url == "https://acme.es.us-east-1.aws.elastic-cloud.com"
      assert sink.api_key == "es-test-key"
      assert sink.data_stream == "logs-firezone-default"

      assert base = Repo.get_by(Portal.LogSink, account_id: account.id, id: sink.id)
      assert base.type == :elastic
    end

    test "creates a Microsoft Sentinel log sink with its base row", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/log_sinks/sentinel/new")

      tenant_id = Ecto.UUID.generate()

      form =
        form(lv, "#log-sink-form",
          log_sink: %{
            name: "SOC Sentinel",
            tenant_id: tenant_id,
            ingestion_endpoint: "https://dce.eastus-1.ingest.monitor.azure.com/",
            dcr_immutable_id: "dcr-0123456789abcdef0123456789abcdef",
            stream_name: "Custom-FirezoneLogs_CL",
            enabled_streams: ["", "session"]
          }
        )

      render_change(form)
      render_submit(form)

      assert sink = Repo.get_by(Portal.Sentinel.LogSink, account_id: account.id)
      assert sink.name == "SOC Sentinel"
      assert sink.tenant_id == tenant_id
      assert sink.ingestion_endpoint == "https://dce.eastus-1.ingest.monitor.azure.com"
      assert sink.dcr_immutable_id == "dcr-0123456789abcdef0123456789abcdef"
      assert sink.stream_name == "Custom-FirezoneLogs_CL"
      assert sink.enabled_streams == [:session]

      assert base = Repo.get_by(Portal.LogSink, account_id: account.id, id: sink.id)
      assert base.type == :sentinel
    end

    test "renders the Sentinel admin consent link for the entered tenant", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/log_sinks/sentinel/new")

      assert html =~ "Monitoring Metrics Publisher"

      assert html =~
               "https://login.microsoftonline.com/organizations/adminconsent?client_id=test_sentinel_client_id"

      assert html =~ "redirect_uri=#{URI.encode_www_form(url(~p"/auth/sentinel/consent"))}"
      assert html =~ "state=#{account.slug}"

      tenant_id = Ecto.UUID.generate()

      html =
        lv
        |> form("#log-sink-form", log_sink: %{tenant_id: tenant_id})
        |> render_change()

      assert html =~
               "https://login.microsoftonline.com/#{tenant_id}/adminconsent?client_id=test_sentinel_client_id"
    end

    test "renders the Sentinel setup tabs with prefilled snippets", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/log_sinks/sentinel/new")

      assert html =~ "/downloads/firezone-sentinel-sample.json"
      assert html =~ "New custom log (DCR-based)"

      sample_conn = get(conn, ~p"/downloads/firezone-sentinel-sample.json")
      assert [record | _] = JSON.decode!(sample_conn.resp_body)
      assert Map.keys(record) == ["Firezone", "Message", "Stream", "TimeGenerated"]

      html =
        lv
        |> element("button[phx-value-tab=cli]")
        |> render_click()

      assert html =~ "az monitor data-collection rule create"
      assert html =~ "az ad sp show --id test_sentinel_client_id"

      html =
        lv
        |> element("button[phx-value-tab=terraform]")
        |> render_click()

      assert html =~ "azurerm_monitor_data_collection_rule"
      assert html =~ "azuread_service_principal"
      assert html =~ "test_sentinel_client_id"
    end

    test "renders validation errors for an invalid DCR immutable ID", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/log_sinks/sentinel/new")

      html =
        lv
        |> form("#log-sink-form",
          log_sink: %{
            name: "SOC Sentinel",
            tenant_id: Ecto.UUID.generate(),
            ingestion_endpoint: "https://dce.eastus-1.ingest.monitor.azure.com",
            dcr_immutable_id: "not-a-dcr-id"
          }
        )
        |> render_change()

      assert html =~ "must look like dcr-"
      assert Repo.all(Portal.Sentinel.LogSink) == []
    end

    test "renders validation errors for an invalid HEC URL", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/log_sinks/splunk/new")

      html =
        lv
        |> form("#log-sink-form",
          log_sink: %{
            name: "SOC Splunk",
            collector_url: "not a url",
            hec_token: "test-hec-token"
          }
        )
        |> render_change()

      assert html =~ "is invalid"
      assert Repo.all(Splunk.LogSink) == []
    end

    test "rejects plaintext and private-address HEC URLs", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/log_sinks/splunk/new")

      html =
        lv
        |> form("#log-sink-form",
          log_sink: %{
            name: "SOC Splunk",
            collector_url: "http://splunk.internal.example:8088",
            hec_token: "test-hec-token"
          }
        )
        |> render_change()

      assert html =~ "only https schemes are supported"

      html =
        lv
        |> form("#log-sink-form",
          log_sink: %{
            name: "SOC Splunk",
            collector_url: "https://169.254.169.254:8088",
            hec_token: "test-hec-token"
          }
        )
        |> render_change()

      assert html =~ "must not be a private or reserved IP address"
      assert Repo.all(Splunk.LogSink) == []
    end
  end

  describe "edit" do
    test "updates the sink, resubmitting the rendered token", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      sink = splunk_log_sink_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/log_sinks/splunk/#{sink.id}/edit")

      form = form(lv, "#log-sink-form", log_sink: %{name: "Renamed Sink"})
      render_change(form)
      render_submit(form)

      updated = reload_sink(sink)
      assert updated.name == "Renamed Sink"
      assert updated.hec_token == sink.hec_token
    end

    test "requires the token", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      sink = splunk_log_sink_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/log_sinks/splunk/#{sink.id}/edit")

      form = form(lv, "#log-sink-form", log_sink: %{name: "Renamed Sink", hec_token: ""})
      render_change(form)
      html = render_submit(form)

      assert html =~ "can&#39;t be blank"

      updated = reload_sink(sink)
      assert updated.name == sink.name
      assert updated.hec_token == sink.hec_token
    end

    test "editing a sink disabled by a delivery error re-enables it", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      sink =
        splunk_log_sink_fixture(
          account: account,
          is_disabled: true,
          disabled_reason: "Sync error",
          error_message: "Splunk HEC returned HTTP 403: Invalid token",
          errored_at: DateTime.utc_now()
        )

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/log_sinks/splunk/#{sink.id}/edit")

      form = form(lv, "#log-sink-form", log_sink: %{hec_token: "fixed-token"})
      render_change(form)
      render_submit(form)

      updated = reload_sink(sink)
      refute updated.is_disabled
      refute updated.disabled_reason
      refute updated.error_message
      refute updated.errored_at
    end
  end

  describe "actions" do
    test "deletes the sink and everything under it", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      sink = splunk_log_sink_fixture(account: account)
      now = DateTime.utc_now()

      Repo.insert_all(LogSinkCursor, [
        %{
          account_id: account.id,
          log_sink_id: sink.id,
          stream: :session,
          phase: :live,
          cursor: 0,
          inserted_at: now,
          updated_at: now
        }
      ])

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/log_sinks")

      open_sink_actions(lv, sink.id)

      lv
      |> element("button[phx-click='delete_sink'][phx-value-id='#{sink.id}']")
      |> render_click()

      assert Repo.all(Splunk.LogSink) == []
      assert Repo.all(Portal.LogSink) == []
      assert Repo.all(LogSinkCursor) == []
    end

    test "disables and re-enables a sink", %{conn: conn, account: account, actor: actor} do
      sink = splunk_log_sink_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/log_sinks")

      open_sink_actions(lv, sink.id)

      lv
      |> element("button[phx-click='toggle_sink'][phx-value-id='#{sink.id}']")
      |> render_click()

      updated = reload_sink(sink)
      assert updated.is_disabled
      assert updated.disabled_reason == "Disabled by admin"

      open_sink_actions(lv, sink.id)

      lv
      |> element("button[phx-click='toggle_sink'][phx-value-id='#{sink.id}']")
      |> render_click()

      updated = reload_sink(sink)
      refute updated.is_disabled
      refute updated.disabled_reason
    end

    test "an error-disabled sink has no enable action", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      sink =
        splunk_log_sink_fixture(
          account: account,
          is_disabled: true,
          disabled_reason: "Sync error",
          error_message: "Splunk HEC returned HTTP 403: Invalid token (code 4)",
          errored_at: DateTime.utc_now()
        )

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/log_sinks")

      html = open_sink_actions(lv, sink.id)

      refute html =~ "toggle-sink-#{sink.id}"
      assert html =~ "delete-sink-#{sink.id}"
    end

    test "deliver now enqueues a sync job", %{conn: conn, account: account, actor: actor} do
      sink = splunk_log_sink_fixture(account: account)

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/log_sinks")

      open_sink_actions(lv, sink.id)

      lv
      |> element("button[phx-click='sync_sink'][phx-value-id='#{sink.id}']")
      |> render_click()

      assert_enqueued(worker: Splunk.Sync, args: %{log_sink_id: sink.id})
    end

    test "deliver now rejects sinks from other accounts", %{
      conn: conn,
      account: account,
      actor: actor
    } do
      other_sink = splunk_log_sink_fixture()

      {:ok, lv, _html} =
        conn
        |> authorize_conn(actor)
        |> live(~p"/#{account}/settings/log_sinks")

      html = render_click(lv, "sync_sink", %{"id" => other_sink.id})

      assert html =~ "Failed to queue log sink delivery."
      refute_enqueued(worker: Splunk.Sync)
    end
  end
end
