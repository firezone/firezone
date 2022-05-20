defmodule FzHttpWeb.UserLive.Index do
  @moduledoc """
  Handles User LiveViews.
  """
  use FzHttpWeb, :live_view

  import Ecto.Changeset
  alias FzHttp.{Repo, Users}

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:users, Users.list_users(:with_device_counts))
     |> assign(:changeset, Users.new_user())
     |> assign(:page_title, "Users")}
  end

  @impl Phoenix.LiveView
  def handle_params(_params, _url, socket) do
    {:noreply, socket}
  end

  @impl Phoenix.LiveView
  def handle_event(
        "toggle_allowed_to_connect",
        %{"_target" => ["allowed-to-connect-" <> user_id]} = params,
        socket
      ) do
    Users.get_user!(user_id)
    |> change
    |> put_change(:allowed_to_connect, !!params["allowed-to-connect-#{user_id}"])
    |> Repo.update!()

    {:noreply,
     socket
     |> assign(:users, Users.list_users(:with_device_counts))}
  end
end
