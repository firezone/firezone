defmodule Web.LiveMFA do
  @moduledoc """
  Guards content behind MFA
  """
  use Phoenix.Component
  use Web, :helper
  import Phoenix.LiveView
  alias Domain.Auth.MFA

  def on_mount(_arg, _params, %{"logged_in_at" => logged_in_at}, socket) do
    with {:ok, mfa} <- MFA.fetch_last_used_method_by_user_id(socket.assigns.current_user.id),
         true <- DateTime.compare(logged_in_at, mfa.last_used_at) == :gt do
      {:halt, redirect(socket, to: ~p"/mfa/auth/#{mfa.id}")}
    else
      {:error, :not_found} -> {:cont, socket}
      false -> {:cont, socket}
    end
  end

  def on_mount(_arg, _params, _session, socket) do
    {:halt, redirect(socket, to: ~p"/")}
  end
end
