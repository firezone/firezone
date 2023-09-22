defmodule Web.Nav do
  use Web, :verified_routes

  def on_mount(:set_active_sidebar_item, _params, _session, socket) do
    {:cont, Phoenix.LiveView.attach_hook(socket, :active_path, :handle_params, &set_active_path/3)}
  end

  defp set_active_path(_params, uri, socket) do
    {:cont, Phoenix.Component.assign(socket, :active_path, URI.parse(uri).path)}
  end
end
