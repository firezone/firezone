defmodule FzHttpWeb.RuleLive.Index do
  @moduledoc """
  Handles Rule LiveViews.
  """
  use FzHttpWeb, :live_view

  def mount(params, session, socket) do
    {:ok,
     socket
     |> assign_defaults(params, session)
     |> assign(:page_title, "Egress Rules")}
  end
end
