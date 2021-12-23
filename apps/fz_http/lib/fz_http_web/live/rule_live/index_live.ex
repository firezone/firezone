defmodule FzHttpWeb.RuleLive.Index do
  @moduledoc """
  Handles Rule LiveViews.
  """
  use FzHttpWeb, :live_view

  def mount(params, session, socket) do
    {:ok,
     socket
     |> assign_defaults(params, session, &load_data/2)}
  end

  defp load_data(_params, socket) do
    user = socket.assigns.current_user

    if user.role == :admin do
      socket
      |> assign(:page_title, "Egress Rules")
    else
      not_authorized(socket)
    end
  end
end
