defmodule FzHttpWeb.LiveAuth do
  @moduledoc """
  Handles loading default assigns and authorizing.
  """

  import Phoenix.LiveView
  import FzHttpWeb.AuthorizationHelpers
  alias FzHttp.Users

  @guardian_token_name "guardian_default_token"

  def on_mount(:admin, _params, %{@guardian_token_name => token} = _session, socket) do
    socket
    |> assign_new(:current_user, fn -> Users.get_user(user_id_from_token(token)) end)
    |> authorize_role(:admin)
  end

  def on_mount(:unprivileged, _params, %{@guardian_token_name => token} = _session, socket) do
    socket
    |> assign_new(:current_user, fn -> Users.get_user(user_id_from_token(token)) end)
    |> authorize_role(:unprivileged)
  end

  def on_mount(_scope, _params, _session, socket) do
    {:halt, not_authorized(socket)}
  end

  defp user_id_from_token(_token) do
    1
  end
end
