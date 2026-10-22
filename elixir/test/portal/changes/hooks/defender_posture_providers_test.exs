defmodule Portal.Changes.Hooks.DefenderPostureProvidersTest do
  use ExUnit.Case, async: true
  import Portal.Changes.Hooks.DefenderPostureProviders
  alias Portal.{Changes.Change, Defender, PubSub}

  @account_id "00000000-0000-0000-0000-000000000000"
  @data %{
    "id" => "00000000-0000-0000-0000-000000000001",
    "account_id" => @account_id,
    "tenant_id" => "00000000-0000-0000-0000-000000000002"
  }

  setup do
    :ok = PubSub.Changes.subscribe(@account_id, :posture_providers)
  end

  # The run writes synced_at when it finishes, which is what tells an open
  # settings page to re-read its counts.
  test "broadcasts a finished sync" do
    synced = Map.put(@data, "synced_at", "2026-08-21T00:00:00.000000Z")

    assert :ok == on_update(0, @data, synced)

    assert_receive %Change{
      op: :update,
      old_struct: %Defender.PostureProvider{synced_at: nil},
      struct: %Defender.PostureProvider{} = provider
    }

    assert provider.tenant_id == "00000000-0000-0000-0000-000000000002"
    assert provider.synced_at == ~U[2026-08-21 00:00:00.000000Z]
  end

  test "broadcasts an added provider" do
    assert :ok == on_insert(0, @data)
    assert_receive %Change{op: :insert, struct: %Defender.PostureProvider{}}
  end

  test "broadcasts a deleted provider" do
    assert :ok == on_delete(0, @data)
    assert_receive %Change{op: :delete, old_struct: %Defender.PostureProvider{}}
  end
end
