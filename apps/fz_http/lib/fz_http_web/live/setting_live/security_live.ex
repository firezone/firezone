defmodule FzHttpWeb.SettingLive.Security do
  @moduledoc """
  Manages security LiveView
  """
  use FzHttpWeb, :live_view

  @impl Phoenix.LiveView
  def mount(params, session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Security Settings")
     |> assign_defaults(params, session)}
  end
end
