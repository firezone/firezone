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

  defp message_tag(message) when is_struct(message), do: message.__struct__
  defp message_tag(message) when is_tuple(message) and tuple_size(message) > 0, do: elem(message, 0)
  defp message_tag(message) when is_atom(message), do: message
  defp message_tag(_message), do: :unknown
end
