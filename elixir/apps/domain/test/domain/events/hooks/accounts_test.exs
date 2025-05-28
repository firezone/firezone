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
    test "returns :ok", %{old_data: old_data, data: data} do
      assert :ok == on_update(old_data, data)
    end

    test "sends :config_changed if config changes" do
      account = Fixtures.Accounts.create_account()

      :ok = subscribe(account.id)

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
    end

    test "does not send :config_changed if config does not change" do
      account = Fixtures.Accounts.create_account()

      :ok = subscribe(account.id)

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
  end

  describe "delete/1" do
    test "returns :ok", %{data: data} do
      assert :ok == on_delete(data)
    end
  end
end
