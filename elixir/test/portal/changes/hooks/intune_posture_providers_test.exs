defmodule Portal.Changes.Hooks.IntunePostureProvidersTest do
  use ExUnit.Case, async: true
  import Portal.Changes.Hooks.IntunePostureProviders
  alias Portal.{Changes.Change, Intune, PubSub}

  @account_id "00000000-0000-0000-0000-000000000000"
  @data %{
    "id" => "00000000-0000-0000-0000-000000000001",
    "account_id" => @account_id,
    "tenant_id" => "contoso.onmicrosoft.com"
  }

  setup do
    :ok = PubSub.Changes.subscribe(@account_id, :posture_providers)
  end

  # The error handler disables a provider without the sync knowing, so this is
  # what moves an open settings page off "Active".
  test "broadcasts a provider a sync error disabled" do
    disabled = Map.merge(@data, %{"is_disabled" => "true", "disabled_reason" => "Sync error"})

    assert :ok == on_update(0, @data, disabled)

    assert_receive %Change{
      op: :update,
      struct: %Intune.PostureProvider{is_disabled: true, disabled_reason: "Sync error"}
    }
  end

  test "broadcasts an added provider" do
    assert :ok == on_insert(0, @data)

    assert_receive %Change{
      op: :insert,
      struct: %Intune.PostureProvider{tenant_id: "contoso.onmicrosoft.com"}
    }
  end

  test "broadcasts a deleted provider" do
    assert :ok == on_delete(0, @data)
    assert_receive %Change{op: :delete, old_struct: %Intune.PostureProvider{}}
  end
end
