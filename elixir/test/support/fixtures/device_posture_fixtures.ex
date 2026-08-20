defmodule Portal.DevicePostureFixtures do
  @moduledoc """
  Test helpers shared by every posture provider.

  For provider-specific structs use `Portal.IntuneFixtures` or
  `Portal.IruFixtures`.
  """

  import Portal.AccountFixtures

  @doc """
  Turns on the global half of the device_posture flag for the current test.

  The account half is set through `account_fixture(features: ...)`; both must be
  on for the REST API and the settings LiveView to allow anything.
  """
  def enable_device_posture(enabled? \\ true)
  def enable_device_posture(true), do: Portal.FeaturesFixtures.enable_feature(:device_posture)
  def enable_device_posture(false), do: Portal.FeaturesFixtures.disable_feature(:device_posture)

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
