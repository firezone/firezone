defmodule PortalWeb.PoliciesCase do
  @moduledoc false

  defmacro __using__(_opts) do
    quote do
      use PortalWeb.ConnCase, async: true

      import Phoenix.LiveViewTest, except: [live: 2]

      # The table loads in an async task, so wait for it before returning.
      defp live(conn, path) do
        case Phoenix.LiveViewTest.live(conn, path) do
          {:ok, lv, _html} -> {:ok, lv, render_async(lv)}
          other -> other
        end
      end

      alias Portal.{Policy, Repo}
      alias Portal.Changes.Change

      import Portal.AccountFixtures
      import Portal.DevicePostureFixtures
      import Portal.ActorFixtures
      import Portal.AuthProviderFixtures
      import Portal.FeaturesFixtures
      import Portal.GroupFixtures
      import Portal.MembershipFixtures
      import Portal.PolicyAuthorizationFixtures
      import Portal.PolicyFixtures
      import Portal.ResourceFixtures
      import Portal.SiteFixtures
      import Portal.TrustAnchorFixtures

      setup do
        account = account_fixture()
        actor = admin_actor_fixture(account: account)
        %{account: account, actor: actor}
      end
    end
  end
end
