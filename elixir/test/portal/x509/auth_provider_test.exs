defmodule Portal.X509.AuthProviderTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.AuthProviderFixtures

  alias Portal.AuthProvider
  alias Portal.X509.AuthProvider, as: X509AuthProvider

  test "uses account_id and id as its composite primary key" do
    assert X509AuthProvider.__schema__(:primary_key) == [:account_id, :id]
  end

  test "the parent table permits only one X.509 provider per account" do
    account = account_fixture()
    _provider = x509_provider_fixture(account: account)

    changeset =
      %AuthProvider{}
      |> Ecto.Changeset.cast(
        %{id: Ecto.UUID.generate(), type: :x509},
        [:id, :type]
      )
      |> Ecto.Changeset.put_assoc(:account, account)
      |> AuthProvider.changeset()

    assert {:error, changeset} = Repo.insert(changeset)
    assert "already has an X.509 authentication provider" in errors_on(changeset).account_id
  end
end
