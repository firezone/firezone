defmodule Portal.Changes.Hooks.IruPostureProvidersTest do
  use ExUnit.Case, async: true
  import Portal.Changes.Hooks.IruPostureProviders
  alias Portal.{Changes.Change, Iru, PubSub}

  @account_id "00000000-0000-0000-0000-000000000000"
  @data %{
    "id" => "00000000-0000-0000-0000-000000000001",
    "account_id" => @account_id,
    "subdomain" => "acme",
    "region" => "us"
  }

  setup do
    :ok = PubSub.Changes.subscribe(@account_id, :posture_providers)
  end

  # The run writes synced_at when it finishes, which is what tells an open
  # settings page to re-read its counts.
  test "broadcasts a finished sync" do
    synced = Map.put(@data, "synced_at", "2026-08-19T00:00:00.000000Z")

    assert :ok == on_update(0, @data, synced)

    assert_receive %Change{
      op: :update,
      old_struct: %Iru.PostureProvider{synced_at: nil},
      struct: %Iru.PostureProvider{} = provider
    }

    assert provider.subdomain == "acme"
    assert provider.synced_at == ~U[2026-08-19 00:00:00.000000Z]
  end

  test "broadcasts an added provider" do
    assert :ok == on_insert(0, @data)
    assert_receive %Change{op: :insert, struct: %Iru.PostureProvider{subdomain: "acme"}}
  end

  test "broadcasts a deleted provider" do
    assert :ok == on_delete(0, @data)
    assert_receive %Change{op: :delete, old_struct: %Iru.PostureProvider{}}
  end
end
