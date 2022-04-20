defmodule FzHttp.Devices.StatsUpdater do
  @moduledoc """
  Extracts
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
            remote_ip: remote_ip(data.endpoint),
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

  # XXX: Come up with a better way to update devices in Sandbox mode
  defp device_to_update(public_key) do
    if Application.fetch_env!(:fz_http, :sandbox) do
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

  defp remote_ip(endpoint) do
    endpoint
    |> String.split(":")
    |> Enum.at(0)
  end

  defp latest_handshake(epoch) do
    epoch
    |> String.to_integer()
    |> DateTime.from_unix!()
  end
end
