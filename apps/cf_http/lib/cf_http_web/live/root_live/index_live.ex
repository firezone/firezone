defmodule CfHttpWeb.RootLive.Index do
  @moduledoc """
  The Root view; redirects to devices or sign in based on session.
  """
  use CfHttpWeb, :live_view

  def mount(_params, %{"user_id" => _user_id}, socket) do
    {:ok, redirect(socket, to: Routes.device_index_path(socket, :index))}
  end

  def mount(_params, _session, socket) do
    {:ok, redirect(socket, to: Routes.session_new_path(socket, :new))}
  end
end
