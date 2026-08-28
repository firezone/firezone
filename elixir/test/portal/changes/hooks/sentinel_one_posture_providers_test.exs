defmodule Portal.Changes.Hooks.SentinelOnePostureProvidersTest do
  use ExUnit.Case, async: true
  import Portal.Changes.Hooks.SentinelOnePostureProviders
  alias Portal.{Changes.Change, PubSub, SentinelOne}

  @account_id "00000000-0000-0000-0000-000000000000"
  @data %{
    "id" => "00000000-0000-0000-0000-000000000001",
    "account_id" => @account_id,
    "management_url" => "https://acme.sentinelone.net"
  }

  setup do
    :ok = PubSub.Changes.subscribe(@account_id, :posture_providers)
  end

  test "broadcasts a finished sync" do
    synced = Map.put(@data, "synced_at", "2026-08-26T00:00:00.000000Z")

    assert :ok == on_update(0, @data, synced)

    assert_receive %Change{
      op: :update,
      old_struct: %SentinelOne.PostureProvider{synced_at: nil},
      struct: %SentinelOne.PostureProvider{} = provider
    }

    assert provider.management_url == "https://acme.sentinelone.net"
    assert provider.synced_at == ~U[2026-08-26 00:00:00.000000Z]
  end

  test "broadcasts an added provider" do
    assert :ok == on_insert(0, @data)
    assert_receive %Change{op: :insert, struct: %SentinelOne.PostureProvider{}}
  end

  test "broadcasts a deleted provider" do
    assert :ok == on_delete(0, @data)
    assert_receive %Change{op: :delete, old_struct: %SentinelOne.PostureProvider{}}
  end
end
