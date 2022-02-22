defmodule FzHttpWeb.UserLive.Index do
  @moduledoc """
  Handles User LiveViews.
  """
  use FzHttpWeb, :live_view

  alias FzHttp.Users

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:users, Users.list_users(:with_tunnel_counts))
     |> assign(:changeset, Users.new_user())
     |> assign(:page_title, "Users")}
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end
end
