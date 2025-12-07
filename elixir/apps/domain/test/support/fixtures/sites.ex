defmodule Domain.Fixtures.Sites do
  use Domain.Fixture
  alias Domain.Site

  def site_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      name: "site-#{unique_integer()}",
      managed_by: :account
    })
  end

  def create_site(attrs \\ %{}) do
    attrs = site_attrs(attrs)

    {account, attrs} =
      pop_assoc_fixture(attrs, :account, fn assoc_attrs ->
        Fixtures.Accounts.create_account(assoc_attrs)
      end)

    {subject, attrs} =
      pop_assoc_fixture(attrs, :subject, fn assoc_attrs ->
        assoc_attrs
        |> Enum.into(%{account: account, actor: [type: :account_admin_user]})
        |> Fixtures.Auth.create_subject()
      end)

    changeset = Ecto.Changeset.change(%Site{}, attrs)

    {:ok, site} = Repo.insert(changeset)
    site
  end

  def create_internet_site(attrs \\ %{}) do
    attrs =
      site_attrs(attrs)
      |> Map.put(:managed_by, :system)
      |> Map.put(:name, "Internet")

    {account, _attrs} =
      pop_assoc_fixture(attrs, :account, fn assoc_attrs ->
        Fixtures.Accounts.create_account(assoc_attrs)
      end)

    changeset = Ecto.Changeset.change(%Site{}, attrs)

    {:ok, site} = Repo.insert(changeset)

    site
  end
end
