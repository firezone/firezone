defmodule PortalAPI.Gateway.V3.Channel do
  @moduledoc """
  The v3 gateway control protocol: v2 plus metrics export. Gateways on this
  channel receive `metrics_config` pushes after joining, when their token is
  refreshed, and when the account's metric sets change.
  """
  use PortalAPI, :channel
  alias Portal.{AccountMetricSet, Changes.Change}
  alias PortalAPI.MetricsConfig
  alias PortalAPI.Gateway.Channel.Shared

  @impl true
  def join(topic, payload, socket) do
    socket
    |> assign(:channel_protocol, __MODULE__)
    |> then(&Shared.join(topic, payload, &1))
  end

  @impl true
  defdelegate terminate(reason, socket), to: Shared

  @impl true
  def handle_info(:after_join, socket) do
    with {:noreply, socket} <- Shared.handle_info(:after_join, socket) do
      Process.send_after(self(), :refresh_metrics_token, MetricsConfig.refresh_every())
      push_metrics_config(socket)

      {:noreply, socket}
    end
  end

  def handle_info(:refresh_metrics_token, socket) do
    Process.send_after(self(), :refresh_metrics_token, MetricsConfig.refresh_every())
    push_metrics_config(socket)

    {:noreply, socket}
  end

  def handle_info(%Change{} = change, socket) when is_struct(change.struct, AccountMetricSet) or is_struct(change.old_struct, AccountMetricSet) do
    last_lsn = Map.get(socket.assigns, :last_lsn, 0)

    with {:noreply, socket} <- Shared.handle_info(change, socket) do
      if change.lsn > last_lsn, do: push_metrics_config(socket)

      {:noreply, socket}
    end
  end

  def handle_info(message, socket), do: Shared.handle_info(message, socket)

  @impl true
  defdelegate handle_in(message, payload, socket), to: Shared

  defp push_metrics_config(socket) do
    push(socket, "metrics_config", MetricsConfig.render(socket.assigns.account, socket.assigns.gateway))
  end

  @doc false
  def create_authorization_event, do: "create_authorization"
end
