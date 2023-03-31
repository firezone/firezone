defmodule FzHttpWeb.LiveNav do
  @moduledoc """
  Handles admin navigation link highlight
  """

  use Phoenix.Component
  import Phoenix.LiveView

  def on_mount(nil, _params, _session, socket) do
    {:cont, assign(socket, path: nil)}
  end

  def on_mount(_role, _params, _session, socket) do
    {:cont, attach_hook(socket, :url, :handle_params, &assign_path/3)}
  end

  defp assign_path(_params, url, socket) do
    %{path: path} = URI.parse(url)
    {:cont, assign(socket, path: path)}
  end
end
