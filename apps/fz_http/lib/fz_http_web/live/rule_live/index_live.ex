defmodule FzHttpWeb.RuleLive.Index do
  @moduledoc """
  Handles Rule LiveViews.
  """
  use FzHttpWeb, :live_view

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Egress Rules")}
  end
end
