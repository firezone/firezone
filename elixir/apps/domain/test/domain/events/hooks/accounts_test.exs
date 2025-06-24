defmodule Domain.Events.Hooks.AccountsTest do
  use Domain.DataCase, async: true
  import Domain.Events.Hooks.Accounts

  setup do
    %{old_data: %{}, data: %{}}
  end

  describe "insert/1" do
    test "returns :ok", %{data: data} do
      assert :ok == on_insert(data)
    end
  end

  describe "update/2" do
    test "disconnects gateways if slug changes" do
      account = Fixtures.Accounts.create_account()
      gateway = Fixtures.Gateways.create_gateway(account: account)
      :ok = Domain.Gateways.Presence.connect(gateway)

      old_data = %{"slug" => "old"}
      data = %{"slug" => "new", "id" => account.id}

      assert :ok == on_update(old_data, data)

      assert_receive "disconnect"
    end

    test "sends :config_changed if config changes" do
      account = Fixtures.Accounts.create_account()
      gateway = Fixtures.Gateways.create_gateway(account: account)

      :ok = Domain.PubSub.Account.subscribe(account.id)
      :ok = Domain.Gateways.Presence.connect(gateway)

      old_data = %{
        "id" => account.id,
        "config" => %{"search_domain" => "old_value", "clients_upstream_dns" => []}
      }

      data = %{
        "id" => account.id,
        "config" => %{
          "search_domain" => "new_value",
          "clients_upstream_dns" => [%{"protocol" => "ip_port", "address" => "8.8.8.8"}]
        }
      }

      assert :ok == on_update(old_data, data)
      assert_receive :config_changed
      refute_receive "disconnect"
    end

    test "does not send :config_changed if config does not change" do
      account = Fixtures.Accounts.create_account()

      :ok = Domain.PubSub.Account.subscribe(account.id)

      old_data = %{
        "id" => account.id,
        "config" => %{"search_domain" => "old_value", "clients_upstream_dns" => []}
      }

      data = %{
        "id" => account.id,
        "config" => %{"search_domain" => "old_value", "clients_upstream_dns" => []}
      }

      assert :ok == on_update(old_data, data)
      refute_receive :config_changed
    end

    test "sends disconnect to clients if account is disabled" do
      account_id = Fixtures.Accounts.create_account().id

      old_data = %{"id" => account_id, "disabled_at" => nil}
      data = %{"id" => account_id, "disabled_at" => DateTime.utc_now()}

      :ok = Domain.PubSub.Account.Clients.subscribe(account_id)

      assert :ok == on_update(old_data, data)

      assert_receive "disconnect"
    end
  end

  describe "delete/1" do
    test "returns :ok", %{data: data} do
      assert :ok == on_delete(data)
    end
  end
end
