defmodule FzHttpWeb.UserLive.VPNConnectionComponent do
  @moduledoc """
  Handles user form.
  """
  use FzHttpWeb, :live_component

  import Ecto.Changeset
  alias FzHttp.Repo

  @impl Phoenix.LiveComponent
  def render(assigns) do
    ~H"""
    <label class="switch is-large">
      <input type="checkbox" phx-target={@myself} phx-click="toggle_disabled_at"
          data-confirm="Are you sure? This may affect this user's internet connectivity."
          disabled={assigns[:disabled]}
          checked={!@user.disabled_at} value={if(@user.disabled_at, do: "on")} />
      <span class="check"></span>
    </label>
    """
  end

  @impl Phoenix.LiveComponent
  def handle_event("toggle_disabled_at", params, socket) do
    to_disable = !params["value"]

    user =
      socket.assigns.user
      |> change()
      |> put_change(
        :disabled_at,
        if(to_disable, do: DateTime.utc_now(), else: nil)
      )
      |> prepare_changes(fn
        %{changes: %{disabled_at: nil}} = changeset ->
          changeset

        %{data: user} = changeset ->
          FzHttp.Telemetry.disable_user()
          FzHttpWeb.Endpoint.broadcast("users_socket:#{user.id}", "disconnect", %{})
          changeset
      end)
      |> Repo.update!()

    {:noreply, assign(socket, :user, user)}
  end
end
