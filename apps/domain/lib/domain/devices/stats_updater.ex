defmodule Domain.Devices.StatsUpdater do
  @moduledoc """
  Extracts WireGuard data about each peer and adds it to
  the correspond device.
  """
  alias Domain.{Devices, Devices.Device, Repo}

  def update(stats) do
    for {public_key, data} <- stats do
      Device.Query.by_public_key(public_key)
      |> Repo.fetch()
      |> case do
        {:ok, device} ->
          attrs = %{
            rx_bytes: String.to_integer(data.rx_bytes),
            tx_bytes: String.to_integer(data.tx_bytes),
            remote_ip: endpoint_to_ip(data.endpoint),
            latest_handshake: latest_handshake(data.latest_handshake)
          }

          {resp, _} = Devices.update_metrics(device, attrs)

          resp

        {:error, :not_found} ->
          :ok
      end
    end
  end

  defp latest_handshake(epoch) do
    epoch
    |> String.to_integer()
    |> DateTime.from_unix!()
  end

  def endpoint_to_ip(endpoint) do
    endpoint
    |> String.replace(~r{:\d+$}, "")
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
  end
end
