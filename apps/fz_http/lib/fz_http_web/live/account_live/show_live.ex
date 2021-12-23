defmodule FzHttpWeb.AccountLive.Show do
  @moduledoc """
  Handles Account-related things.
  """
  use FzHttpWeb, :live_view

  alias FzHttp.Users

  @impl Phoenix.LiveView
  def mount(params, session, socket) do
    {:ok,
     socket
     |> assign_defaults(params, session, &load_data/2)
     |> assign(:page_title, "Account")}
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  defp load_data(_params, socket) do
    user = socket.assigns.current_user

    if user.role == :admin do
      socket
      |> assign(:changeset, Users.change_user(socket.assigns.current_user))
    else
      not_authorized(socket)
    end
  end
end
