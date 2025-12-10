defmodule Domain.Workers.OutdatedGatewaysTest do
  use Domain.DataCase, async: true
  import Domain.Workers.OutdatedGateways
  alias Domain.{ComponentVersions, Gateways}

  describe "execute/1" do
    setup do
      account_attrs = %{
        config: %{
          notifications: %{
            outdated_gateway: %{
              enabled: true,
              last_notified: nil
            }
          }
        }
      }

      account =
        Fixtures.Accounts.create_account(account_attrs)
        |> Fixtures.Accounts.change_to_enterprise()

      site = Fixtures.Sites.create_site(account: account)
      token = Fixtures.Sites.create_token(account: account, site: site)

      %{
        account: account,
        site: site,
        token: token
      }
    end

    test "sends notification for outdated gateways", %{
      account: account,
      site: site,
      token: token
    } do
      # Create Gateway
      gateway = Fixtures.Gateways.create_gateway(account: account, site: site)
      version = gateway.last_seen_version

      # Set ComponentVersions
      new_version = bump_version(version)
      new_config = update_component_versions_config(gateway: new_version)
      Domain.Config.put_env_override(ComponentVersions, new_config)

      :ok = Gateways.Presence.Site.subscribe(site.id)
      {:ok, _} = Gateways.Presence.Site.track(gateway.site_id, gateway.id, token.id)
      {:ok, _} = Gateways.Presence.Account.track(gateway.account_id, gateway.id)
      assert_receive %Phoenix.Socket.Broadcast{topic: "presences:group_gateways:" <> _}

      assert execute(%{}) == :ok

      assert_email_sent(fn email ->
        assert email.subject == "Firezone Gateway Upgrade Available"
        assert email.text_body =~ "The latest Firezone Gateway release is: #{new_version}"
      end)
    end

    test "does not send notification if gateway up to date", %{
      account: account,
      site: site,
      token: token
    } do
      # Create Gateway
      gateway = Fixtures.Gateways.create_gateway(account: account, site: site)
      version = gateway.last_seen_version

      # Set ComponentVersions
      new_config = update_component_versions_config(gateway: version)
      Domain.Config.put_env_override(ComponentVersions, new_config)

      :ok = Gateways.Presence.Site.subscribe(site.id)
      {:ok, _} = Gateways.Presence.Site.track(gateway.site_id, gateway.id, token.id)
      {:ok, _} = Gateways.Presence.Account.track(gateway.account_id, gateway.id)

      assert_receive %Phoenix.Socket.Broadcast{topic: "presences:group_gateways:" <> _}

      assert execute(%{}) == :ok
      refute_email_sent()
    end
  end

  defp bump_version(version) do
    {:ok, current_version} = Version.parse(version)
    new_minor = current_version.minor + 1
    "#{current_version.major}.#{new_minor}.0"
  end

  defp update_component_versions_config(versions) do
    config = Domain.Config.get_env(:domain, Domain.ComponentVersions)

    new_versions =
      Keyword.get(config, :versions)
      |> Keyword.merge(versions)

    Keyword.merge(config, versions: new_versions)
  end
end
