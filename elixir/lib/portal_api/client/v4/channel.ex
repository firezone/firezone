defmodule PortalAPI.Client.V4.Channel do
  @moduledoc """
  The v4 client control protocol: v3 plus metrics export. Clients on this channel
  receive `metrics_config` pushes after joining, when their token is refreshed or
  the signing key rotates, and when the account's metrics settings change.
  """
  use PortalAPI, :channel
  alias Portal.{Account, Changes.Change}
  alias PortalAPI.MetricsConfig
  alias PortalAPI.Client.Channel.Shared

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
      :ok = Portal.MetricsToken.subscribe_to_key_rotations()
      Process.send_after(self(), :refresh_metrics_token, MetricsConfig.refresh_every())
      push_metrics_config(socket)

      {:noreply, socket}
    end
  end

  def handle_info(:refresh_metrics_token, socket) do
    Process.send_after(self(), :refresh_metrics_token, MetricsConfig.refresh_every())
    if socket.assigns.subject.account.metrics_export, do: push_metrics_config(socket)

    {:noreply, socket}
  end

  def handle_info(:metrics_token_key_rotated, socket) do
    if socket.assigns.subject.account.metrics_export, do: push_metrics_config(socket)

    {:noreply, socket}
  end

  def handle_info(
        %Change{op: :update, old_struct: %Account{} = old_account, struct: %Account{} = account} =
          change,
        socket
      ) do
    with {:noreply, socket} <- Shared.handle_info(change, socket) do
      if MetricsConfig.changed?(old_account, account), do: push_metrics_config(socket)

      {:noreply, socket}
    end
  end

  def handle_info(message, socket), do: Shared.handle_info(message, socket)

  @impl true
  defdelegate handle_in(message, payload, socket), to: Shared

  defp push_metrics_config(socket) do
    push(socket, "metrics_config", MetricsConfig.render(socket.assigns.subject.account, socket.assigns.client))
  end

  @doc false
  def protocol_version, do: 4

  @doc false
  def authorization_created_event, do: "authorization_created"

  @doc false
  def authorization_creation_failed_event, do: "authorization_creation_failed"
end
