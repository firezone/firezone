defmodule PortalWeb.Settings.DevicePostureCase do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      use PortalWeb.ConnCase, async: true
      use Oban.Testing, repo: Portal.Repo

      import Portal.ActorFixtures
      import Portal.DevicePostureFixtures
      import Portal.IntuneFixtures
      import Portal.IruFixtures
      import Portal.DefenderFixtures
      import Portal.SantaFixtures
      import Portal.SentinelOneFixtures

      setup do
        Portal.Config.put_env_override(Portal.Mailer.PostureProviderInterestEmail,
          recipient: "feedback@example.com"
        )

        account = device_posture_account_fixture()
        actor = admin_actor_fixture(account: account)
        %{account: account, actor: actor}
      end

      def reload(provider) do
        provider.__struct__
        |> Portal.Repo.get_by!(account_id: provider.account_id, id: provider.id)
        |> Map.put(:name, provider_name(provider))
      end

      # The name lives on the shared posture_providers row.
      def provider_name(provider) do
        Portal.Repo.get_by!(Portal.PostureProvider,
          account_id: provider.account_id,
          id: provider.id
        ).name
      end

      def reverify(lv, tenant_id) do
        if has_element?(lv, "button[phx-click=reset_verification]") do
          lv |> element("button[phx-click=reset_verification]") |> render_click()
        end

        lv |> element("#provider-verification-button") |> render_click()
        assert_push_event(lv, "open_url", %{url: url})

        state = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")
        {:ok, %{verification_ref: ref}} = PortalWeb.OIDC.verify_verification_state(state)

        # The OIDC controller consumes the pending verifier before the callback
        # completes, which is what promotes it to the active verification.
        send(lv.pid, {:get_pending_verification, self()})
        assert_receive {:pending_verification, %{verification_ref: ^ref}}

        ack_ref = make_ref()

        send(lv.pid, {:intune_posture_provider_complete, tenant_id, ref, {self(), ack_ref}})
        assert_receive {:verification_ack, ^ack_ref}

        lv
      end

    end
  end
end
