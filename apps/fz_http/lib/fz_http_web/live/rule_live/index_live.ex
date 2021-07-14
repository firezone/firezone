defmodule FzHttpWeb.RuleLive.Index do
  @moduledoc """
  Handles Rule LiveViews.
  """
  use FzHttpWeb, :live_view

  def mount(params, session, socket) do
    {:ok, assign_defaults(params, session, socket)}
  end
end
