defmodule Portal.Changes.Hooks.X509AuthProvidersTest do
  use Portal.DataCase, async: true

  import Portal.Changes.Hooks.X509AuthProviders
  alias Portal.Changes.Change
  alias Portal.PubSub
  alias Portal.X509.AuthProvider

  setup do
    account_id = Ecto.UUID.generate()
    provider_id = Ecto.UUID.generate()

    data = %{
      "id" => provider_id,
      "account_id" => account_id,
      "name" => "X.509",
      "context" => "clients_only",
      "is_disabled" => false
    }

    :ok = PubSub.Changes.subscribe(account_id, :x509_auth_providers)

    %{account_id: account_id, provider_id: provider_id, data: data}
  end

  test "broadcasts an inserted X.509 auth provider", %{data: data, provider_id: provider_id} do
    assert :ok = on_insert(1, data)

    assert_receive %Change{
      lsn: 1,
      op: :insert,
      struct: %AuthProvider{id: ^provider_id, context: :clients_only, is_disabled: false}
    }
  end

  test "broadcasts an updated X.509 auth provider", %{data: data, provider_id: provider_id} do
    assert :ok = on_update(2, data, %{data | "is_disabled" => true})

    assert_receive %Change{
      lsn: 2,
      op: :update,
      old_struct: %AuthProvider{id: ^provider_id, is_disabled: false},
      struct: %AuthProvider{id: ^provider_id, is_disabled: true}
    }
  end

  test "broadcasts a deleted X.509 auth provider", %{data: data, provider_id: provider_id} do
    assert :ok = on_delete(3, data)

    assert_receive %Change{
      lsn: 3,
      op: :delete,
      old_struct: %AuthProvider{id: ^provider_id}
    }
  end
end
