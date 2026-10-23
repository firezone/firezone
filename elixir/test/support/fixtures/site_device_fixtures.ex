defmodule Portal.SiteDeviceFixtures do
  @moduledoc """
  Test helpers for assigning a device to a site.
  """

  import Portal.AccountFixtures
  import Portal.DeviceFixtures
  import Portal.SiteFixtures

  @doc """
  Assigns a device to a site. The site, device, and account are created
  unless provided; the default device is a gateway of that site, which the
  mirror trigger already assigns, so an existing assignment is returned as is.

  ## Examples

      site_device = site_device_fixture()
      site_device = site_device_fixture(site: site, device: device)

  """
  def site_device_fixture(attrs \\ %{}) do
    attrs = Enum.into(attrs, %{})

    account =
      cond do
        site = Map.get(attrs, :site) ->
          Portal.Repo.preload(site, :account).account

        device = Map.get(attrs, :device) ->
          Portal.Repo.preload(device, :account).account

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
      |> Portal.Repo.insert(
        on_conflict: :nothing,
        conflict_target: [:account_id, :site_id, :device_id]
      )

    site_device
  end
end
