defmodule Portal.Entra.TenantUniquenessTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.AuthProviderFixtures

  alias Portal.Entra.AuthProvider

  @first "00000000-0000-4000-8000-000000000001"
  @middle "00000000-0000-4000-8000-000000000002"
  @last "00000000-0000-4000-8000-000000000003"
  @other "00000000-0000-4000-8000-000000000004"

  test "rejects overlapping sets regardless of array order, including partial overlap" do
    account = account_fixture()
    entra_provider_fixture(account: account, tenant_ids: [@first, @last])
    for tenant_ids <- [[@first, @last], [@last, @first], [@other, @last]] do
      changeset = new_provider(account, tenant_ids)
      assert {:error, failed} = Repo.insert(changeset, mode: :savepoint)
      assert "A tenant is already verified on another Entra authentication provider in this account." in errors_on(failed).tenant_ids
    end
  end

  test "allows distinct tenants between set endpoints and reuse in another account" do
    account = account_fixture()
    entra_provider_fixture(account: account, tenant_ids: [@first, @last])
    assert {:ok, _} = account |> new_provider([@middle]) |> Repo.insert()
    assert {:ok, _} = account_fixture() |> new_provider([@first, @last]) |> Repo.insert()
  end

  test "disabled providers and different contexts still reserve their tenants" do
    account = account_fixture()
    entra_provider_fixture(account: account, tenant_ids: [@first], is_disabled: true, context: :portal_only)
    assert {:error, failed} = account |> new_provider([@first]) |> Repo.insert(mode: :savepoint)
    assert errors_on(failed).tenant_ids != []
  end

  test "rejects conflicting updates and preserves the saved array" do
    account = account_fixture()
    first = entra_provider_fixture(account: account, tenant_ids: [@first])
    assert {:ok, second} = account |> new_provider([@last]) |> Repo.insert()
    assert {:error, failed} = second |> change(tenant_ids: [@last, @first], is_verified: true)
      |> AuthProvider.changeset() |> Repo.update(mode: :savepoint)
    assert errors_on(failed).tenant_ids != []
    assert Repo.reload!(second).tenant_ids == [@last]
    assert Repo.reload!(first).tenant_ids == [@first]
  end

  test "removing a tenant or deleting a provider releases the tenant" do
    account = account_fixture()
    provider = entra_provider_fixture(account: account, tenant_ids: [@first, @last])
    provider = provider |> change(tenant_ids: [@first]) |> Repo.update!()
    assert {:ok, _} = account |> new_provider([@last]) |> Repo.insert()
    Repo.delete!(provider)
    assert {:ok, _} = account |> new_provider([@first]) |> Repo.insert()
  end

  test "enforces overlap even for SQL that bypasses the changeset" do
    account = account_fixture()
    entra_provider_fixture(account: account, tenant_ids: [@first])
    assert {:ok, second} = account |> new_provider([@last]) |> Repo.insert()
    assert {:error, %Postgrex.Error{postgres: %{code: :exclusion_violation}}} =
      Repo.query("UPDATE entra_auth_providers SET tenant_ids = $1 WHERE id = $2",
        [[Ecto.UUID.dump!(@first)], Ecto.UUID.dump!(second.id)], mode: :savepoint)
    assert Repo.reload!(second).tenant_ids == [@last]
  end

  defp new_provider(account, tenant_ids) do
    base = auth_provider_fixture(account: account, type: :entra)
    %AuthProvider{id: base.id, account_id: account.id}
    |> cast(%{name: "Entra #{base.id}", tenant_ids: tenant_ids, is_verified: true}, [:name, :tenant_ids, :is_verified])
    |> AuthProvider.changeset()
  end
end
