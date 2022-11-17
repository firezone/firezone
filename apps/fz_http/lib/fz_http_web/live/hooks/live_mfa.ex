defmodule FzHttpWeb.LiveMFA do
  @moduledoc """
  Guards content behind MFA
  """
  use Phoenix.Component
  import Phoenix.LiveView
  use FzHttpWeb, :helper

  def on_mount(_, _params, session, socket) do
    with %{"mfa_required_at" => mfa_required_at} <- session,
         %{last_used_at: last_used_at} <-
           FzHttp.MFA.most_recent_method(socket.assigns.current_user),
         :gt <- DateTime.compare(mfa_required_at, last_used_at) do
      {:halt, redirect(socket, to: ~p"/mfa/auth")}
    else
      _ ->
        {:cont, socket}
    end
  end
end
