defmodule Portal.Changes.Hooks.SantaPostureProvidersTest do
  use ExUnit.Case, async: true
  import Portal.Changes.Hooks.SantaPostureProviders
  alias Portal.{Changes.Change, PubSub, Santa}

  @account_id "00000000-0000-0000-0000-000000000000"
  @data %{
    "id" => "00000000-0000-0000-0000-000000000001",
    "account_id" => @account_id,
    "api_url" => "https://acme.workshop.cloud"
  }

  setup do
    :ok = PubSub.Changes.subscribe(@account_id, :posture_providers)
  end

  test "broadcasts a finished sync" do
    synced = Map.put(@data, "synced_at", "2026-08-26T00:00:00.000000Z")

    assert :ok == on_update(0, @data, synced)

    assert_receive %Change{
      op: :update,
      old_struct: %Santa.PostureProvider{synced_at: nil},
      struct: %Santa.PostureProvider{} = provider
    }

    assert provider.api_url == "https://acme.workshop.cloud"
    assert provider.synced_at == ~U[2026-08-26 00:00:00.000000Z]
  end

  test "broadcasts an added and a deleted provider" do
    assert :ok == on_insert(0, @data)
    assert_receive %Change{op: :insert, struct: %Santa.PostureProvider{}}

    assert :ok == on_delete(1, @data)
    assert_receive %Change{op: :delete, old_struct: %Santa.PostureProvider{}}
  end
end
