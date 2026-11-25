defmodule Portal.Changes.Hooks.SiteDevicesTest do
  use ExUnit.Case, async: true
  import Portal.Changes.Hooks.SiteDevices
  alias Portal.{Changes.Change, PubSub, SiteDevice}

  setup do
    account_id = Ecto.UUID.generate()
    :ok = PubSub.Changes.subscribe(account_id, :site_devices)

    data = %{
      "account_id" => account_id,
      "site_id" => Ecto.UUID.generate(),
      "device_id" => Ecto.UUID.generate()
    }

    %{data: data}
  end

  test "broadcasts an inserted row", %{data: data} do
    assert :ok == on_insert(1, data)
    assert_receive %Change{op: :insert, lsn: 1, struct: %SiteDevice{} = site_device}
    assert site_device.device_id == data["device_id"]
  end

  test "broadcasts an updated row", %{data: data} do
    new_data = Map.put(data, "site_id", Ecto.UUID.generate())
    assert :ok == on_update(2, data, new_data)
    assert_receive %Change{op: :update, lsn: 2, old_struct: %SiteDevice{} = old, struct: %SiteDevice{} = new}
    assert old.site_id == data["site_id"]
    assert new.site_id == new_data["site_id"]
  end

  test "broadcasts a deleted row", %{data: data} do
    assert :ok == on_delete(3, data)
    assert_receive %Change{op: :delete, lsn: 3, old_struct: %SiteDevice{} = site_device}
    assert site_device.site_id == data["site_id"]
  end
end
