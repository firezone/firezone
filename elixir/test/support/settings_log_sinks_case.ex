defmodule PortalWeb.Settings.LogSinksCase do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      use PortalWeb.ConnCase, async: true
      use Oban.Testing, repo: Portal.Repo

      import Phoenix.LiveViewTest
      import Portal.AccountFixtures
      import Portal.ActorFixtures
      import Portal.LogSinkFixtures

      alias Portal.LogSinkCursor
      alias Portal.Repo
      alias Portal.Splunk

      setup do
        account = account_fixture(features: %{log_sinks: true})
        actor = admin_actor_fixture(account: account)
        %{account: account, actor: actor}
      end

      def reload_sink(sink) do
        Repo.get_by!(Splunk.LogSink, account_id: sink.account_id, id: sink.id)
      end

      # The Sentinel tenant has no input; it only ever arrives from the admin
      # consent tenant proof.
      def verify_sentinel_tenant(lv, tenant_id) do
        lv |> element("#sentinel-consent-link") |> render_click()
        assert_push_event(lv, "open_url", %{url: consent_url})

        {:ok, %{verification_ref: verification_ref}} =
          consent_url
          |> URI.parse()
          |> Map.fetch!(:query)
          |> URI.decode_query()
          |> Map.fetch!("state")
          |> PortalWeb.OIDC.verify_verification_state()

        send(lv.pid, {:sentinel_log_sink_complete, tenant_id, verification_ref})
        render(lv)

        tenant_id
      end

      def maybe_verify_tenant(lv, "sentinel"), do: verify_sentinel_tenant(lv, Ecto.UUID.generate())
      def maybe_verify_tenant(_lv, _type), do: :ok

      def sink_fixture(sink_type, attrs) do
        apply(Portal.LogSinkFixtures, sink_type.fixture, [attrs])
      end

      def name_field_error(html) do
        html
        |> Floki.parse_document!()
        |> Floki.find(~s([data-validation-error-for="log_sink[name]"]))
        |> Floki.text()
      end

      def form_error_count(html, field) do
        html
        |> Floki.parse_document!()
        |> Floki.find(~s([data-validation-error-for="log_sink[#{field}]"]))
        |> length()
      end

      # Changes one field the way a browser does: inputs the admin has not touched
      # carry an _unused_ marker, which keeps their errors hidden.
      def change_field(lv, sink, target, params, untouched) do
        params =
          untouched
          |> Enum.reduce(params, &Map.put(&2, "_unused_#{&1}", ""))
          |> Map.put_new("enabled_streams", sink.enabled_streams)

        render_change(lv, "validate", %{"_target" => ["log_sink", target], "log_sink" => params})
      end

      def submit_button_disabled?(html) do
        html
        |> Floki.parse_document!()
        |> Floki.find("button[form=log-sink-form][type=submit]")
        |> Floki.attribute("disabled")
        |> Enum.any?()
      end

      def open_sink_actions(lv, sink_id) do
        lv
        |> element("button[phx-click='toggle_sink_actions'][phx-value-id='#{sink_id}']")
        |> render_click()
      end

    end
  end
end
