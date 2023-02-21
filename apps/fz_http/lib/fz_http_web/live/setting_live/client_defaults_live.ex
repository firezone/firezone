defmodule FzHttpWeb.SettingLive.ClientDefaults do
  @moduledoc """
  Manages the defaults view.
  """
  use FzHttpWeb, :live_view
  alias FzHttp.Config

  @page_title "Client Defaults"
  @page_subtitle "Configure default values for generating WireGuard client configurations."

  @impl Phoenix.LiveView
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:changeset, Config.change_config())
      |> assign(:page_subtitle, @page_subtitle)
      |> assign(:page_title, @page_title)

    {:ok, socket}
  end
end
