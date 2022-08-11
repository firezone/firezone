defmodule FzHttpWeb.SettingLive.Site do
  @moduledoc """
  Manages the defaults view.
  """
  use FzHttpWeb, :live_view

  alias FzHttp.Sites

  @page_title "Site Settings"
  @page_subtitle "Configure default WireGuard settings for this site."

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:changeset, changeset())
     |> assign(:page_subtitle, @page_subtitle)
     |> assign(:page_title, @page_title)}
  end

  defp changeset do
    Sites.get_site!() |> Sites.change_site()
  end
end
