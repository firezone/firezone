defmodule Web.LiveHooks.SetActiveSidebarItem do
  use Web, :verified_routes

  def on_mount(:default, _params, _session, socket) do
    {:cont,
     Phoenix.LiveView.attach_hook(socket, :current_path, :handle_params, &set_current_path/3)}
  end

  defp set_current_path(_params, uri, socket) do
    {:cont, Phoenix.Component.assign(socket, :current_path, URI.parse(uri).path)}
  end
end
