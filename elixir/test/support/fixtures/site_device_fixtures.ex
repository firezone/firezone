defmodule Portal.SiteDeviceFixtures do
  @moduledoc """
  Test helpers for assigning a device to a site.
  """

  import Portal.AccountFixtures
  import Portal.DeviceFixtures
  import Portal.SiteFixtures

  @doc """
  Assigns a device to a site. The site, device, and account are created
  unless provided; the default device is a gateway of that site.

  ## Examples

      site_device = site_device_fixture()
      site_device = site_device_fixture(site: site, device: device)

  """
  def site_device_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    account =
      cond do
        site = Map.get(attrs, :site) ->
          site.account || Portal.Repo.preload(site, :account).account

        device = Map.get(attrs, :device) ->
          device.account || Portal.Repo.preload(device, :account).account

        true ->
          Map.get(attrs, :account) || account_fixture()
      end

    site = Map.get(attrs, :site) || site_fixture(account: account)
    device = Map.get(attrs, :device) || gateway_fixture(account: account, site: site)

    {:ok, site_device} =
      %Portal.SiteDevice{}
      |> Ecto.Changeset.cast(
        %{account_id: account.id, site_id: site.id, device_id: device.id},
        [:account_id, :site_id, :device_id]
      )
      |> Portal.SiteDevice.changeset()
      |> Portal.Repo.insert()

    site_device
  end
end
