defmodule Domain.ConfigFixtures do
  alias Domain.Config
  alias Domain.AccountsFixtures

  def configuration_attrs(attrs \\ %{}) do
    Enum.into(attrs, %{
      devices_upstream_dns: ["1.1.1.1"]
    })
  end

  def upsert_configuration(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    {account, attrs} =
      Map.pop_lazy(attrs, :account, fn ->
        AccountsFixtures.create_account()
      end)

    attrs = configuration_attrs(attrs)

    {:ok, configuration} =
      Config.get_account_config_by_account_id(account.id)
      |> Config.update_config(attrs)

    configuration
  end

  def set_config(account, key, value) do
    upsert_configuration([{:account, account}, {key, value}])
  end
end
