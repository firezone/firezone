defmodule PortalWeb.Live.Helpers do
  require Logger

  @spec handle_info_fallback(term(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_info_fallback(message, socket) do
    Logger.error("Unhandled handle_info message in LiveView",
      liveview: socket.view,
      message_tag: message_tag(message)
    )

    {:noreply, socket}
  end

  @doc """
  Ignores an event when `stale?.(event, assigns)` returns true.

  The browser can send an event from a panel after the server has already
  closed that panel, for example a click that was in flight during the patch.
  """
  @spec drop_stale_events(Phoenix.LiveView.Socket.t(), (String.t(), map() -> boolean())) ::
          Phoenix.LiveView.Socket.t()
  def drop_stale_events(socket, stale?) do
    Phoenix.LiveView.attach_hook(socket, :drop_stale_events, :handle_event, fn event, _params, socket ->
      if stale?.(event, socket.assigns) do
        {:halt, socket}
      else
        {:cont, socket}
      end
    end)
  end

  defp message_tag(message) when is_struct(message), do: message.__struct__
  defp message_tag(message) when is_tuple(message) and tuple_size(message) > 0, do: elem(message, 0)
  defp message_tag(message) when is_atom(message), do: message
  defp message_tag(_message), do: :unknown
end
