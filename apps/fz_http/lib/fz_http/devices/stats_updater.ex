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
            rx_bytes: String.to_integer(data.rx_bytes),
            tx_bytes: String.to_integer(data.tx_bytes),
            remote_ip: FzCommon.FzNet.endpoint_to_ip(data.endpoint),
            latest_handshake: latest_handshake(data.latest_handshake)
          }

          {resp, _} =
            device
            |> Device.update_changeset(attrs)
            |> Repo.update()

          resp
      end
    end
  end

  defp device_to_update(public_key) do
    Repo.one(
      from d in Device,
        where: d.public_key == ^public_key
    )
  end

  defp latest_handshake(epoch) do
    epoch
    |> String.to_integer()
    |> DateTime.from_unix!()
  end
end
