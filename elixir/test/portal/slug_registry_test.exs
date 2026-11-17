defmodule Portal.SlugRegistryTest do
  use ExUnit.Case, async: true

  alias Portal.SlugRegistry

  test "uses the local adapter without a registry table URL" do
    assert SlugRegistry.adapter() == SlugRegistry.Local
  end

  test "uses the Azure Table adapter with a registry table URL" do
    Portal.Config.put_env_override(:slug_registry_table_url, "https://registry.example.test")
    assert SlugRegistry.adapter() == SlugRegistry.AzureTable
  end

  test "the local adapter never leaves the database" do
    account_id = Ecto.UUID.generate()

    assert SlugRegistry.claim("Any-Slug", account_id) == :ok
    assert SlugRegistry.lookup("any-slug") == :not_found
    assert SlugRegistry.release("any-slug", account_id) == :ok
    assert SlugRegistry.transfer(account_id, :eu) == {:ok, 0}
    assert SlugRegistry.list_region(:us) == {:ok, []}
  end
end
