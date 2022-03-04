defmodule FzHttpWeb.SettingLive.SiteFormComponent do
  @moduledoc """
  Handles updating site values.
  """
  use FzHttpWeb, :live_component

  alias FzHttp.Sites

  @impl Phoenix.LiveComponent
  def update(assigns, socket) do
    {:ok,
     socket
     |> assign(assigns)}
  end

  @impl Phoenix.LiveComponent
  def handle_event("save", %{"site" => site_params}, socket) do
    site = Sites.get_site!()

    case Sites.update_site(site, site_params) do
      {:ok, site} ->
        {:noreply,
         socket
         |> assign(:changeset, Sites.change_site(site))}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:changeset, changeset)}
    end
  end
end
