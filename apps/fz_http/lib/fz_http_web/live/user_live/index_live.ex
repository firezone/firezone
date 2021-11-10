defmodule FzHttpWeb.UserLive.Index do
  @moduledoc """
  Handles User LiveViews.
  """
  use FzHttpWeb, :live_view

  alias FzHttp.Users

  @impl Phoenix.LiveView
  def mount(params, session, socket) do
    {:ok,
     socket
     |> assign_defaults(params, session, &load_data/2)
     |> assign(:changeset, Users.new_user())
     |> assign(:page_title, "Users")}
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  defp load_data(_params, socket) do
    assign(
      socket,
      :users,
      Users.list_users(:with_device_counts)
    )
  end
end
