defmodule Domain.Mailer.NotificationsTest do
  alias Domain.ComponentVersions
  use Domain.DataCase, async: true
  import Domain.Mailer.Notifications

  setup do
    account = Fixtures.Accounts.create_account()

    %{
      account: account
    }
  end

  describe "outdated_gateway_email/3" do
    test "should contain current gateway version and list of outdated gateways", %{
      account: account
    } do
      admin_email = "admin@foo.local"

      gateway_1 = Fixtures.Gateways.create_gateway(account: account)
      gateway_2 = Fixtures.Gateways.create_gateway(account: account)

      current_version = "3.2.1"
      set_current_version(current_version)

      email_body = outdated_gateway_email(account, [gateway_1, gateway_2], admin_email)

      assert email_body.text_body =~ "The latest Firezone Gateway release is: #{current_version}"
      assert email_body.text_body =~ gateway_1.name
      assert email_body.text_body =~ gateway_2.name
    end
  end

  defp set_current_version(version) do
    config = Domain.Config.get_env(:domain, ComponentVersions)

    new_versions =
      config
      |> Keyword.get(:versions)
      |> Keyword.merge(gateway: version)

    new_config = Keyword.merge(config, versions: new_versions)
    Domain.Config.put_env_override(:domain, ComponentVersions, new_config)
  end
end
