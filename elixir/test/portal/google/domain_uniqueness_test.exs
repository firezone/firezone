defmodule Portal.Google.DomainUniquenessTest do
  use Portal.DataCase, async: true

  import Ecto.Query
  import Portal.AccountFixtures
  import Portal.AuthProviderFixtures

  alias Portal.Google.AuthProvider

  test "allows multiple disjoint Workspace providers alongside one unrestricted provider" do
    account = account_fixture()
    personal = google_provider_fixture(account: account, workspace_domains: nil)
    google_provider_fixture(account: account, name: "First Workspace", workspace_domains: ["alpha.example", "zeta.example"])
    assert {:ok, _} = account |> new_provider(["middle.example"]) |> Repo.insert()
    assert Repo.reload!(personal).workspace_domains == nil
    assert Repo.aggregate(from(p in AuthProvider, where: p.account_id == ^account.id), :count) == 3
  end

  test "allows only one unrestricted provider, including disabled providers" do
    account = account_fixture()
    google_provider_fixture(account: account, workspace_domains: nil, is_disabled: true)
    assert {:error, failed} = account |> new_provider(nil) |> Repo.insert(mode: :savepoint)
    assert "Only one Google authentication provider without Workspace domains is allowed per account." in errors_on(failed).workspace_domains
  end

  test "rejects overlap regardless of order, case, or whitespace" do
    account = account_fixture()
    google_provider_fixture(account: account, workspace_domains: ["alpha.example", "zeta.example"])
    for domains <- [["zeta.example", "alpha.example"], ["other.example", "zeta.example"], ["ALPHA.EXAMPLE"], [" alpha.example "]] do
      assert {:error, failed} = account |> new_provider(domains) |> Repo.insert(mode: :savepoint)
      assert "A domain is already verified on another Google authentication provider in this account." in errors_on(failed).workspace_domains
    end
  end

  test "reserves domains on disabled providers and permits reuse in another account" do
    account = account_fixture()
    google_provider_fixture(account: account, workspace_domains: ["work.example"], is_disabled: true, context: :portal_only)
    assert {:error, _} = account |> new_provider(["work.example"]) |> Repo.insert(mode: :savepoint)
    assert {:ok, _} = account_fixture() |> new_provider(["work.example"]) |> Repo.insert()
  end

  test "rejects overlapping updates and leaves the stored list unchanged" do
    account = account_fixture()
    google_provider_fixture(account: account, workspace_domains: ["first.example"])
    assert {:ok, second} = account |> new_provider(["second.example"]) |> Repo.insert()
    assert {:error, failed} = second |> change(workspace_domains: ["second.example", "first.example"], is_verified: true)
      |> AuthProvider.changeset() |> Repo.update(mode: :savepoint)
    assert errors_on(failed).workspace_domains != []
    assert Repo.reload!(second).workspace_domains == ["second.example"]
  end

  test "empty and null-element arrays cannot bypass the single unrestricted provider rule" do
    account = account_fixture()
    google_provider_fixture(account: account, workspace_domains: nil)
    assert {:ok, provider} = account |> new_provider(["work.example"]) |> Repo.insert()
    for domains <- [[], [nil], [""]] do
      assert {:error, %Postgrex.Error{postgres: %{code: :check_violation}}} =
        Repo.query("UPDATE google_auth_providers SET workspace_domains = $1 WHERE id = $2",
          [domains, Ecto.UUID.dump!(provider.id)], mode: :savepoint)
    end
    assert {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} =
      Repo.query("UPDATE google_auth_providers SET workspace_domains = NULL WHERE id = $1",
        [Ecto.UUID.dump!(provider.id)], mode: :savepoint)
    assert Repo.reload!(provider).workspace_domains == ["work.example"]
  end

  test "removing a domain or deleting a provider releases it" do
    account = account_fixture()
    provider = google_provider_fixture(account: account, workspace_domains: ["first.example", "second.example"])
    provider = provider |> change(workspace_domains: ["first.example"]) |> Repo.update!()
    assert {:ok, _} = account |> new_provider(["second.example"]) |> Repo.insert()
    Repo.delete!(provider)
    assert {:ok, _} = account |> new_provider(["first.example"]) |> Repo.insert()
  end

  defp new_provider(account, domains) do
    base = auth_provider_fixture(account: account, type: :google)
    %AuthProvider{id: base.id, account_id: account.id}
    |> cast(%{name: "Google #{base.id}", issuer: "https://accounts.google.com", workspace_domains: domains, is_verified: true},
      [:name, :issuer, :workspace_domains, :is_verified])
    |> AuthProvider.changeset()
  end
end
