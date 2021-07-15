defmodule FzHttpWeb.AccountLive.Show do
  @moduledoc """
  Handles Account-related things.
  """
  use FzHttpWeb, :live_view

  alias FzHttp.Users

  @impl true
  def mount(params, session, socket) do
    {:ok,
     socket
     |> assign_defaults(params, session, &load_data/2)}
  end

  @impl true
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  defp load_data(_params, socket) do
    socket
    |> assign(:changeset, Users.change_user(socket.assigns.current_user))
  end
end
