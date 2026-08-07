defmodule Portal.FirezoneSupport.AuthProviderTest do
  use Portal.DataCase, async: true

  import Portal.AccountFixtures
  import Portal.AuthProviderFixtures

  alias Portal.FirezoneSupport

  describe "provider creation" do
    test "creates a provider with parent row and 24h expiry" do
      provider = firezone_support_provider_fixture()

      parent = Portal.Repo.get_by!(Portal.AuthProvider, id: provider.id)
      assert parent.type == :firezone_support
      assert parent.account_id == provider.account_id
      assert DateTime.after?(provider.expires_at, DateTime.utc_now())
    end

    test "enforces one provider per account" do
      account = account_fixture()
      firezone_support_provider_fixture(account: account)

      auth_provider = auth_provider_fixture(type: :firezone_support, account: account)

      {:error, changeset} =
        %FirezoneSupport.AuthProvider{}
        |> Ecto.Changeset.cast(
          %{expires_at: DateTime.add(DateTime.utc_now(), 86_400, :second)},
          [:expires_at]
        )
        |> Ecto.Changeset.put_change(:id, auth_provider.id)
        |> Ecto.Changeset.put_assoc(:account, account)
        |> Ecto.Changeset.put_assoc(:auth_provider, auth_provider)
        |> FirezoneSupport.AuthProvider.changeset()
        |> Portal.Repo.insert()

      assert "Support access is already active for this account." in
               errors_on(changeset).account_id
    end

    test "requires a future expires_at" do
      changeset =
        %FirezoneSupport.AuthProvider{}
        |> Ecto.Changeset.change(
          id: Ecto.UUID.generate(),
          account_id: Ecto.UUID.generate(),
          expires_at: DateTime.add(DateTime.utc_now(), -60, :second)
        )
        |> FirezoneSupport.AuthProvider.changeset()

      refute changeset.valid?
    end
  end

  describe "cascade behavior" do
    test "deleting the parent auth provider deletes the child row" do
      provider = firezone_support_provider_fixture()

      Portal.Repo.get_by!(Portal.AuthProvider, id: provider.id)
      |> Portal.Repo.delete!()

      refute Portal.Repo.get_by(FirezoneSupport.AuthProvider, id: provider.id)
    end
  end

end
