defmodule Portal.DevicePostureFixtures do
  @moduledoc """
  Test helpers shared by every posture provider.

  For provider-specific structs use `Portal.IntuneFixtures`,
  `Portal.IruFixtures`, `Portal.DefenderFixtures`, or `Portal.SantaFixtures`.
  """

  import Portal.AccountFixtures

  def disable_device_posture(account) do
    account
    |> Ecto.Changeset.change(features: %{account.features | device_posture: false})
    |> Portal.Repo.update!()
  end

  def device_posture_account_fixture(attrs \\ %{}) do
    attrs
    |> Enum.into(%{})
    |> Map.update(:features, %{device_posture: true}, &Map.put(&1, :device_posture, true))
    |> account_fixture()
  end

  @doc """
  Inserts the shared row a provider of any type owns its id and name on.
  """
  def posture_provider_fixture(account, id, type, name) do
    %Portal.PostureProvider{}
    |> Ecto.Changeset.change(%{id: id, account_id: account.id, type: type, name: name})
    |> Portal.PostureProvider.changeset()
    |> Portal.Repo.insert!()
  end
end
