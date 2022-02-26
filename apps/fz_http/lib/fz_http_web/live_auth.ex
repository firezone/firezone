defmodule FzHttpWeb.LiveAuth do
  @moduledoc """
  Handles loading default assigns and authorizing.
  """

  alias FzHttpWeb.Authentication
  import Phoenix.LiveView
  import FzHttpWeb.AuthorizationHelpers

  def on_mount(role, _params, session, socket) do
    user = Authentication.get_current_user(session)

    if user do
      socket
      |> assign_new(:current_user, fn -> user end)
      |> authorize_role(role)
    else
      {:halt, not_authorized(socket)}
    end
  end
end
