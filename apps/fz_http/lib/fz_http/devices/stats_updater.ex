defmodule FzHttp.Devices.StatsUpdater do
  @moduledoc """
  Extracts WireGuard data about each peer and adds it to
  the correspond device.
  """

  import Ecto.Query, warn: false
  alias FzHttp.{Devices.Device, Repo}

  def update(stats) do
    for {public_key, data} <- stats do
      case device_to_update(public_key) do
        nil ->
          :ok

        device ->
          attrs = %{
            rx_bytes: data["rx_bytes"],
            tx_bytes: data["tx_bytes"],
            remote_ip: data["endpoint"],
            latest_handshake: latest_handshake(data["handshake_age"])
          }

          {resp, _} =
            device
            |> Device.update_changeset(attrs)
            |> Repo.update()

          resp
      end
    end
  end

  # XXX: Come up with a better way to update devices in Sandbox mode
  defp device_to_update(public_key) do
    if FzHttp.Config.fetch_env!(:fz_http, :sandbox) do
      Repo.one(
        from Device,
          order_by: fragment("RANDOM()"),
          limit: 1
      )
    else
      Repo.one(
        from d in Device,
          where: d.public_key == ^public_key
      )
    end
  end

  defp latest_handshake(epoch) do
    if epoch != nil do
      epoch
      |> DateTime.from_unix!()
    else
      nil
    end
  end
end
