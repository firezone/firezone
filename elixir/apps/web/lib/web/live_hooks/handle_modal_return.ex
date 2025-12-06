defmodule Web.LiveHooks.HandleModalReturn do
  use Web, :verified_routes

  def on_mount(:default, _params, _session, socket) do
    {:cont,
     Phoenix.LiveView.attach_hook(socket, :modal_return, :handle_params, &store_return_to/3)}
  end

  defp store_return_to(params, _uri, socket) do
    socket =
      case params do
        %{"return_to" => return_to} ->
          Phoenix.Component.assign(socket, :modal_return_to, return_to)

        # Clear the return_to when we're not in a modal context (no live_action or default action)
        _ ->
          if Map.get(socket.assigns, :live_action) in [nil, :index] do
            Phoenix.Component.assign(socket, :modal_return_to, nil)
          else
            socket
          end
      end

    {:cont, socket}
  end
end
