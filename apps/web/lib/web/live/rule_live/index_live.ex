defmodule Web.RuleLive.Index do
  @moduledoc """
  Handles Rule LiveViews.
  """
  use Web, :live_view

  @page_title "Egress Rules"
  @page_subtitle "Firewall rules to apply to the kernel's forward chain."

  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_subtitle, @page_subtitle)
     |> assign(:page_title, @page_title)}
  end
end
