defmodule FzHttpWeb.LiveAuth do
  @moduledoc """
  Handles loading default assigns and authorizing.
  """

  alias FzHttpWeb.Authentication
  import Phoenix.LiveView
  import FzHttpWeb.AuthorizationHelpers

  def on_mount(role, _params, session, socket) do
    case Authentication.resource_from_session(session) do
      {:ok, user, _claims} ->
        socket
        |> assign_new(:current_user, fn -> user end)
        |> authorize_role(role)

      {:error, _reason} ->
        {:halt, not_authorized(socket)}
    end
  end
end
