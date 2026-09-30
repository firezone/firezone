defmodule Portal.Changes.Hooks.SophosPostureProvidersTest do
  use ExUnit.Case, async: true
  import Portal.Changes.Hooks.SophosPostureProviders
  alias Portal.{Changes.Change, PubSub, Sophos}

  @account_id "00000000-0000-0000-0000-000000000000"
  @data %{
    "id" => "00000000-0000-0000-0000-000000000001",
    "account_id" => @account_id,
    "tenant_id" => "57ca9a6b-885f-4e36-95ec-290548c26059"
  }

  setup do
    :ok = PubSub.Changes.subscribe(@account_id, :posture_providers)
  end

  test "broadcasts a finished sync" do
    synced = Map.put(@data, "synced_at", "2026-08-26T00:00:00.000000Z")

    assert :ok == on_update(0, @data, synced)

    assert_receive %Change{
      op: :update,
      old_struct: %Sophos.PostureProvider{synced_at: nil},
      struct: %Sophos.PostureProvider{} = provider
    }

    assert provider.tenant_id == "57ca9a6b-885f-4e36-95ec-290548c26059"
    assert provider.synced_at == ~U[2026-08-26 00:00:00.000000Z]
  end

  test "broadcasts an added provider" do
    assert :ok == on_insert(0, @data)
    assert_receive %Change{op: :insert, struct: %Sophos.PostureProvider{}}
  end

  test "broadcasts a deleted provider" do
    assert :ok == on_delete(0, @data)
    assert_receive %Change{op: :delete, old_struct: %Sophos.PostureProvider{}}
  end
end
