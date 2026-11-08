defmodule PortalWeb.Settings.AuthenticationCase do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      use PortalWeb.ConnCase, async: true

      import Ecto.Query
      import Portal.AccountFixtures
      import Portal.ActorFixtures
      import Portal.AuthProviderFixtures
      import Portal.FeaturesFixtures
      import Portal.TokenFixtures
      import Portal.PortalSessionFixtures
      import Portal.PolicyFixtures
      import Portal.TrustAnchorFixtures

      alias Portal.EmailOTP
      alias PortalWeb.Mocks

      # =============================================================================
      # Test Setup Helpers
      # =============================================================================

      setup do
        account = account_fixture()
        actor = admin_actor_fixture(account: account)

        %{account: account, actor: actor}
      end

      def request_confirm(lv, action, provider_id) do
        lv
        |> element("button[phx-click='toggle_provider_actions'][phx-value-id='#{provider_id}']")
        |> render_click()

        lv
        |> element(
          "button[phx-click='request_confirm'][phx-value-action='#{action}'][phx-value-id='#{provider_id}']"
        )
        |> render_click()
      end

      def open_provider_actions(lv, provider_id) do
        lv
        |> element("button[phx-click='toggle_provider_actions'][phx-value-id='#{provider_id}']")
        |> render_click()
      end

      def has_provider_action_button?(html, action, provider_id) do
        html
        |> Floki.parse_fragment!()
        |> Floki.find(
          "button[phx-click='request_confirm'][phx-value-action='#{action}'][phx-value-id='#{provider_id}']"
        )
        |> Enum.any?()
      end

      def confirm_action(lv, event, provider_id) do
        lv
        |> element("button[phx-click='#{event}'][phx-value-id='#{provider_id}']")
        |> render_click()
      end

      def provider_row_text(html, provider_id) do
        html
        |> Floki.parse_fragment!()
        |> Floki.find("tr")
        |> Enum.find(&(Floki.text(&1) =~ provider_id))
        |> Floki.text(sep: " ")
        |> String.replace(~r/\s+/, " ")
        |> String.trim()
      end

      def verification_ref_from_open_url(lv) do
        assert_push_event(lv, "open_url", %{url: url})
        send(self(), {:opened_url, url})

        %{"state" => state} =
          url
          |> URI.parse()
          |> Map.fetch!(:query)
          |> URI.decode_query()

        assert {:ok, %{verification_ref: verification_ref, lv_pid: serialized_pid}} =
                 PortalWeb.OIDC.verify_verification_state(state)

        assert PortalWeb.OIDC.deserialize_pid(serialized_pid) == lv.pid

        send(lv.pid, {:get_pending_verification, self()})

        assert_receive {:pending_verification, %{verification_ref: ^verification_ref}}

        verification_ref
      end

      # =============================================================================
      # Basic Page Rendering Tests
      # =============================================================================

      def allowlist_provider_fixture("entra", account, values),
        do: entra_provider_fixture(account: account, tenant_ids: values)

      def allowlist_provider_fixture("google", account, values),
        do: google_provider_fixture(account: account, workspace_domains: values)

      def complete_allowlist_verification(lv, type, value, proven \\ []) do
        lv |> element("#verify-button") |> render_click()
        verification_ref = verification_ref_from_open_url(lv)
        html = send_allowlist_verification(lv, type, value, verification_ref, proven)
        toggle = "#verified-organizations input[phx-value-domain='#{value}']"

        if type == "google" and has_element?(lv, toggle) and not has_element?(lv, "#{toggle}[checked]") do
          lv |> element(toggle) |> render_click()
        else
          html
        end
      end

      def send_allowlist_verification(lv, type, value, verification_ref, proven \\ []) do
        ack_ref = make_ref()
        message = case type do
          "entra" -> {:entra_verify_complete, "https://login.microsoftonline.com/#{value}/v2.0",
            value, "Customer tenant", verification_ref, {self(), ack_ref}}
          "google" -> {:google_verify_complete, "https://accounts.google.com", proven ++ [value], value,
            verification_ref, {self(), ack_ref}}
        end
        send(lv.pid, message)
        assert_receive {:verification_ack, ^ack_ref}
        render(lv)
      end

      # =============================================================================
      # Form Submit Error Path Tests
      # =============================================================================

    end
  end
end
