defmodule Portal.Changes.Hooks.SiteDevicesTest do
  use ExUnit.Case, async: true
  import Portal.Changes.Hooks.SiteDevices
  alias Portal.{Changes.Change, PubSub, SiteDevice}

  @account_id "00000000-0000-0000-0000-000000000001"
  @site_id "00000000-0000-0000-0000-000000000002"
  @device_id "00000000-0000-0000-0000-000000000003"

  @data %{
    "account_id" => @account_id,
    "site_id" => @site_id,
    "device_id" => @device_id,
    "inserted_at" => "2026-10-22T00:00:00Z"
  }

  setup do
    :ok = PubSub.Changes.subscribe(@account_id, :site_devices)
  end

  describe "insert/1" do
    test "broadcasts the assignment" do
      assert :ok == on_insert(0, @data)

      assert_receive %Change{op: :insert, struct: %SiteDevice{} = site_device, lsn: 0}
      assert site_device.site_id == @site_id
      assert site_device.device_id == @device_id
    end
  end

  describe "update/2" do
    test "returns :ok" do
      assert :ok == on_update(0, @data, @data)
      refute_receive %Change{}
    end
  end

  describe "delete/1" do
    test "broadcasts the removal" do
      assert :ok == on_delete(0, @data)

      assert_receive %Change{op: :delete, old_struct: %SiteDevice{} = site_device, lsn: 0}
      assert site_device.site_id == @site_id
    end
  end
end
