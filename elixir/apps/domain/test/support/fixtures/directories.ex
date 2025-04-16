defmodule Domain.Fixtures.Directories do
  use Domain.Fixture
  alias Domain.Directories

  def create_okta_provider(attrs \\ %{}) do
    attrs =
      %{
        type: :okta,
        config: %{
          client_id: "test_client_id",
          private_key: "test_private_key",
          okta_domain: "test"
        }
      }
      |> Map.merge(Enum.into(attrs, %{}))

    {account, attrs} =
      pop_assoc_fixture(attrs, :account, fn assoc_attrs ->
        Fixtures.Accounts.create_account(assoc_attrs)
      end)

    {:ok, provider} = Directories.create_provider(account, attrs)

    provider
  end
end
