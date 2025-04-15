defmodule Domain.Fixtures.Directories do
  use Domain.Fixture
  alias Domain.Directories

  def create_okta_provider(attrs \\ %{}) do
    attrs =
      %{type: :okta}
      |> Map.merge(Enum.into(attrs, %{}))

    {account, attrs} =
      pop_assoc_fixture(attrs, :account, fn assoc_attrs ->
        Fixtures.Accounts.create_account(assoc_attrs)
      end)

    {auth_provider, attrs} =
      pop_assoc_fixture(attrs, :auth_provider, fn assoc_attrs ->
        Fixtures.Auth.create_okta_provider(assoc_attrs)
      end)

    {:ok, provider} =
      Directories.create_provider(account, auth_provider, attrs)

    provider
  end
end
